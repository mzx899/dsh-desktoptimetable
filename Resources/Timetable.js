/* 桌面课表 · 卡片渲染
 *
 * 这是旧版 Übersicht widget（~/.Trash/旧课表系统工程/src/index_next.jsx）的界面，
 * 改写成无框架的原生 JS —— 不依赖 React、不依赖 Übersicht、不需要构建步骤。
 * DOM 结构与旧版逐节点对应，样式全部来自 Timetable.css（同样是旧版原样搬过来的）。
 *
 * 与原生 App 的约定：
 *   · 原生 → 网页：window.ttUpdate(json)  推入一份状态快照
 *   · 网页 → 原生：window.webkit.messageHandlers.tt.postMessage({action, payload})
 * 网页层只做展示和交互，不保存业务状态；周次、课程数据一律以原生推入的为准。
 */
(function () {
  'use strict';

  var MAX_WEEK = 16;   // 缺省值，render() 时用 S.maxWeek 覆盖

  var PERIODS = [
    { s: '08:00', e: '08:45' },
    { s: '08:50', e: '09:35' },
    { s: '10:05', e: '10:50' },
    { s: '10:55', e: '11:40' },
    { s: '14:00', e: '14:45' },
    { s: '14:50', e: '15:35' },
    { s: '16:05', e: '16:50' },
    { s: '16:55', e: '17:40' },
    { s: '18:40', e: '19:25' },
    { s: '19:30', e: '20:15' }
  ];

  var DAYS = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

  var PALETTE = {
    '数据结构': ['#4f8cff', 'rgba(79,140,255,'],
    '业务需求建模': ['#a577ff', 'rgba(165,119,255,'],
    '计算机网络基础': ['#2ec4b6', 'rgba(46,196,182,'],
    '系统测试与质量管理': ['#f5a524', 'rgba(245,165,36,'],
    '学术语言与研究方法（中级）': ['#f2569b', 'rgba(242,86,155,'],
    '军事理论': ['#93c05b', 'rgba(147,192,91,'],
    '马克思主义基本原理': ['#ef5f5b', 'rgba(239,95,91,'],
    '形势与政策（三）': ['#35b9e6', 'rgba(53,185,230,'],
    '体育(三)篮球': ['#ff8a3d', 'rgba(255,138,61,']
  };

  // ---- 颜色（唯一来源是原生推过来的 `color`）----
  //
  // 原生 `TimetableState.webJSON` 会把**解析好的**颜色推过来（显式色 > 按课名 > 灰），
  // 网页只负责画。`PALETTE` 只作兜底（老数据 / 单独跑网页），
  // 不要再在这里维护第二份课程颜色。
  var HEX_RE = /^#[0-9a-f]{6}$/;
  var FALLBACK_HEX = '#8b93a7';

  // '#4f8cff' → 'rgba(79,140,255,'（rgba 前缀由 hex 算，不做颜色名解析）
  function rgbaPrefix(hex) {
    return 'rgba(' + parseInt(hex.slice(1, 3), 16) + ','
      + parseInt(hex.slice(3, 5), 16) + ','
      + parseInt(hex.slice(5, 7), 16) + ',';
  }

  // 返回 [hex, 'rgba(r,g,b,']，和 PALETTE 的形状一致，调用点不用改。
  function paletteOf(c) {
    if (c && typeof c.color === 'string') {
      var h = c.color.trim().toLowerCase();
      if (HEX_RE.test(h)) return [h, rgbaPrefix(h)];
    }
    if (c && PALETTE[c.name]) return PALETTE[c.name];
    return [FALLBACK_HEX, rgbaPrefix(FALLBACK_HEX)];
  }

  var S = null;   // 原生推入的状态
  var sel = null; // 当前展开的课程详情

  // ---- 极简 DOM 构造（替代 React.createElement）----
  function h(tag, attrs) {
    var el = document.createElement(tag);
    if (attrs) {
      for (var k in attrs) {
        if (!Object.prototype.hasOwnProperty.call(attrs, k)) continue;
        var v = attrs[k];
        if (v === null || v === undefined || v === false) continue;
        if (k === 'style') {
          if (typeof v === 'string') {
            el.setAttribute('style', v);
          } else {
            for (var p in v) {
              // CSS 自定义属性（--tt-*）必须走 setProperty，直接赋值不生效
              if (p.slice(0, 2) === '--') el.style.setProperty(p, String(v[p]));
              else el.style[p] = v[p];
            }
          }
        } else if (k === 'class') {
          el.className = v;
        } else if (k === 'text') {
          el.textContent = v;
        } else if (k.slice(0, 2) === 'on') {
          el.addEventListener(k.slice(2).toLowerCase(), v);
        } else {
          el.setAttribute(k, v);
        }
      }
    }
    for (var i = 2; i < arguments.length; i++) append(el, arguments[i]);
    return el;
  }

  function append(parent, child) {
    if (child === null || child === undefined || child === false) return;
    if (Array.isArray(child)) {
      for (var i = 0; i < child.length; i++) append(parent, child[i]);
      return;
    }
    parent.appendChild(typeof child === 'object' ? child : document.createTextNode(String(child)));
  }

  // ---- 工具函数（与旧版一致）----
  function toMin(t) {
    var p = t.split(':');
    return parseInt(p[0], 10) * 60 + parseInt(p[1], 10);
  }

  function pad(n) { return n < 10 ? '0' + n : '' + n; }

  function fmtGap(mins) {
    if (mins < 60) return mins + ' 分钟';
    var h_ = Math.floor(mins / 60);
    var m = mins % 60;
    return m ? h_ + ' 小时 ' + m + ' 分' : h_ + ' 小时';
  }

  function cleanLoc(s) {
    return (s || '').replace(/\(学校本部\)/g, '').replace(/\(新校区\)/g, '');
  }

  function briefLoc(s) {
    var parts = cleanLoc(s).split(' / ');
    return parts.length > 1 ? parts[0] + ' 等' : parts[0];
  }

  function briefTeacher(s) {
    var parts = (s || '').split('/');
    return parts.length > 1 ? parts[0] + ' 等' : parts[0];
  }

  // 学期开始日期解析成「本地时间的周一零点」，避免 new Date('YYYY-MM-DD') 被当成 UTC
  function parseSemesterStart(s) {
    var d = null;
    if (s && typeof s === 'object' && typeof s.start === 'string') s = s.start;
    if (typeof s === 'string') {
      var m = s.match(/^(\d{4})-(\d{2})-(\d{2})/);
      if (m) d = new Date(+m[1], +m[2] - 1, +m[3]);
    }
    if (!d) d = new Date(2026, 7, 31);
    d.setHours(0, 0, 0, 0);
    var wd = (d.getDay() + 6) % 7;   // 周一=0 ... 周日=6
    d.setDate(d.getDate() - wd);
    return d;
  }

  function fmtMD(d) { return (d.getMonth() + 1) + '月' + d.getDate() + '日'; }

  function weekMonday(week, semStart) {
    var d = new Date(semStart.getTime());
    d.setDate(d.getDate() + (week - 1) * 7);
    return d;
  }

  function weekDateText(week, semStart) {
    if (!week) return '';
    var s = weekMonday(week, semStart);
    var e = new Date(s.getTime());
    e.setDate(e.getDate() + 6);
    return fmtMD(s) + ' – ' + fmtMD(e);
  }

  function weekDayDate(week, semStart, d) {
    var m = weekMonday(week, semStart);
    m.setDate(m.getDate() + (d - 1));
    m.setHours(0, 0, 0, 0);
    return m;
  }

  function semesterRangeText(semStart) {
    var s = new Date(semStart.getTime());
    var e = new Date(semStart.getTime());
    e.setDate(e.getDate() + (MAX_WEEK - 1) * 7 + 6);
    return fmtMD(s) + ' – ' + fmtMD(e);
  }

  function blockStart(bi) { return PERIODS[bi * 2].s; }
  function blockEnd(bi) { return PERIODS[bi * 2 + 1].e; }

  // ---- 与原生通信 ----
  function post(action, payload) {
    if (typeof window !== 'undefined' && window.__ttPostTrace &&
        (action === 'textInputBlur' || action === 'textInputFocus')) {
      try {
        window.__ttPostTrace.push(action + '@' + Math.round(performance.now()) +
          ':' + (new Error()).stack.split('\n').slice(1, 3).join(' <- '));
      } catch (e) {}
    }
    // 自检用：记下最近一次发给原生的 intent（只存在网页内存里，不影响流程）。
    // `--verify-day-panel` 靠它确认「点添加待办」立刻发了 `todoCompose`。
    //
    // ⚠️ 焦点消息不算「用户意图」：提交时 `todoUpdate` / `todoAdd` 之后
    // 还会跟一条 `textInputBlur`，如果它也覆盖 `__ttLastPost`，自检就
    // 永远看不到真正要验的动作。原始消息另存一份给需要看焦点的用例。
    var entry = { action: action, payload: payload || null };
    window.__ttLastAnyPost = entry;
    // ⚠️ `panelRect` 是**几何回报**（原生算悬停 / 穿透用），不是用户意图 ——
    // 也写进 `__ttLastPost` 的话，自检里「最后发的意图是什么」全被它顶掉。
    if (action !== 'textInputFocus' && action !== 'textInputBlur'
        && action !== 'panelRect') {
      window.__ttLastPost = entry;
    }
    try {
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.tt) {
        window.webkit.messageHandlers.tt.postMessage({ action: action, payload: payload || null });
      }
    } catch (e) { /* 原生没接上时忽略 */ }
  }

  // ---- 齿轮图标（与旧版 SVG 完全一致）----
  function gearIcon() {
    var NS = 'http://www.w3.org/2000/svg';
    var svg = document.createElementNS(NS, 'svg');
    svg.setAttribute('width', '15');
    svg.setAttribute('height', '15');
    svg.setAttribute('viewBox', '0 0 24 24');
    svg.setAttribute('fill', 'none');
    svg.setAttribute('stroke', 'currentColor');
    svg.setAttribute('stroke-width', '1.7');
    svg.setAttribute('stroke-linecap', 'round');
    svg.setAttribute('stroke-linejoin', 'round');
    var c = document.createElementNS(NS, 'circle');
    c.setAttribute('cx', '12'); c.setAttribute('cy', '12'); c.setAttribute('r', '3.1');
    var p = document.createElementNS(NS, 'path');
    p.setAttribute('d', 'M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06A1.65 1.65 0 0 0 9 4.6a1.65 1.65 0 0 0 1-1.51V3a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 1 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z');
    svg.appendChild(c);
    svg.appendChild(p);
    return svg;
  }

  // =====================================================================
  // 日期覆盖层（Day Panel）
  //
  // 规格：docs/日期覆盖层-规格.md
  //   · 点表头日期 → 在那一列上覆盖一个面板（表头不被覆盖）
  //   · 顶边贴着表头格底边，向下延伸；宽度（窄态）= 单列宽度
  //   · 出现：高度 0 → 满列高的向下生长动画
  //   · 材质：基本不透明 + 毛玻璃（沿用 .sheet 的 rgba(30,33,42,.96) 调子）
  //   · 尾部渐变：实心区高度自适应，实心区底部往下一直渐变到底
  //   · 宽态左右两边用 CSS mask 渐隐（内容本身也一起淡出）
  //
  // 状态机：
  //   窄态：鼠标在某列内 → 面板跟到那列；移到不在任何列 → 淡出消失
  //         单击待办条目 → 打勾（todoToggle）；双击 → 撑开
  //   宽态：鼠标换列 → 锁在原列；再双击 → 收回窄态；
  //         再点同一列日期 → 直接关闭；移出课表 → 淡出消失
  //
  // 与原生约定（契约见规格 8.1 / 8.3）：
  //   → 原生：datePanelOpen / datePanelClose
  //             todoToggle / todoAdd / todoDelete
  //             todoMenu（右键只弹菜单，不再直接删除）
  //             todoUpdate（改标题 / 到期时间）
  //   ← 原生：S.dayPanel { day, todos[], events[], festival{} }
  //             S.dayFlags { "1": { todo, event }, ... }
  // =====================================================================

  var DP = {
    // 日记表单状态：null / {mode:'add'} / {mode:'edit', id}
    diaryForm: null,
    // 刚提交、还没等到原生推回来的日记（乐观插入，按标题 + 正文 + 时间去重）
    diaryPending: [],
    // 在「还没拿到真实 id」时点了删除的本地条（等原生推回来再补发 diaryDelete）
    diaryPendingDeletes: [],
    day: null,       // 当前显示的是哪一列（1…7），null = 没打开
    // ⚠️ **不再有「宽态」**（2026-11 去掉双击展开）——
    //
    // 以前双击表头会把面板撑成一个浮在课表格上的大方块。
    // 那个形态的问题：
    //   · 盖住**旁边的列**（用户看得到一个矩形压在课表格上）；
    //   · 底边是**硬边**，横切过课程格，和底板「往下溶」的瀑布不搭；
    //   · 内容其实没多显示多少 —— 卡片化 + 面板内滚动之后，
    //     窄态已经能看全，宽态只剩下「变宽」这一件事。
    //
    // 现在**只有一种形态**：一列宽 + 面板内滚动。
    open: false,     // 是否有可见的覆盖层
    el: null,        // .daypanel 元素
    body: null,      // .dpbody 元素
    fade: null,      // .dpfade 元素
    grid: null,      // .grid 元素（覆盖层的定位父级）
    token: 0,        // 代号：收尾时判断「是不是已经换了面板」
    adding: false,   // 「＋ 添加待办」输入框是否展开
    // ⚠️ **正在关闭**（收起动画在播，400ms）。
    //
    // 以前 `DP.open` 一关闭就立刻置 false → 收起动画还在播的时候，
    // 用户再点一次同一个日期，`onHeaderPick` 看到 `DP.open === false`
    // 就以为「面板没开」→ **又打开** → 用户看到「要点几次才收得回去」
    // （实测：点第一次关掉，第二次又弹出来）。
    //
    // 这个标志表示「正在关闭」——
    // 这期间重复点击**忽略**，不再当成「打开」。
    closing: false,
    // 正在关闭的是**哪一列**（只拦同一列的重复点击）。
    closingDay: null,
    // 「添加待办」的结果提示（失败时显示一行字）。
    //
    // ⚠️ 以前**完全静默**：点了「添加待办」，什么都没发生，
    // 用户不知道是「没权限」还是「点了没反应」。
    addError: '',    // 非空 = 显示这一行提示
    // 上一次 `renderPanel()` 画出来的内容指纹（2026-11 加）。
    //
    // 原生推状态有时**连着推好几版**（内容刷新 / 红点刷新 / 重试），
    // 其中好几版的面板数据完全一样。以前每版都清空 `.dpbody` 重建一遍，
    // 用户看到的是「面板 / 日历闪几下」。
    // 指纹相同就直接跳过重建。
    renderKey: '',
    // 输入框**元素本身**（跨 renderPanel 复用）。
    //
    // ⚠️ 以前每次 renderPanel 都新建一个 <input>，于是：
    //   · 原生每推一次状态 → 整个面板内容重建 → 输入框被换掉
    //     → **焦点丢失、已输入的字全没了**（用户表现为「打不了字」）；
    //   · 就算侥幸保住焦点，`input.focus()` 在非 key 窗口里也无效。
    //
    // 现在输入框只建一次，之后只是**搬进新的卡片里**，
    // 值和焦点都保得住。
    input: null,
    inputValue: '',  // 输入框里的内容（重绘时还原）
    // 「添加待办」的到期时间：时 / 分两个小框（跨重绘复用）。
    //
    // ⚠️ 为什么和标题输入框一样只建一次：原生每推一次状态就会重绘面板，
    // 每次新建输入框的话，用户刚敲进去的时间、光标和焦点都会丢。
    // 这里只换宿主卡片，元素本身不换。
    timeHour: null,
    timeMinute: null,
    timeHourValue: '',
    timeMinuteValue: '',
    hoverDay: null,  // 指针当前所在列（窄态跟随用）
    // ---- 待办编辑态（2026-11）----
    //
    // 右键「修改…」进入**卡片内**编辑，不新开窗口：
    //   · 只改标题和到期时间，完成状态 / 清单归属都不动；
    //   · 回车保存、Esc 取消；
    //   · 原生推状态重绘时复用下面这几个输入元素，不打断输入。
    editingTodoKey: null,   // 正在编辑哪一条（todoKeyOf 算出来的稳定键）
    editTitle: null,
    editHour: null,
    editMinute: null,
    editTitleValue: '',
    editHourValue: '',
    editMinuteValue: '',
    editError: '',
    // 刚进入编辑时，等 renderPanel 把输入框挂回 DOM 之后再自动聚焦标题。
    editFocusPending: false,
    // 自检用：是否已经**请求**过聚焦（隐藏页面里 `hasFocus()` 为 false，
    // 真正的焦点要等原生把窗口临时切成 key 才落到 DOM 上）。
    editFocusRequested: false,
    // 用户已经按了保存、原生还没回包（或晚到的旧快照还在路上）时，
    // 用这份值盖住列表里的旧标题 / 旧时间，避免界面被旧快照改回去。
    //
    // { key, identifier, day, title, time, oldTitle, oldDue }
    pendingEdit: null,
    // 已发过数据请求的列（防重复）——
    // 跟随模式鼠标换列时 openPanel 不发 intent，目标列数据可能没缓存，
    // 补发一次 `datePanelOpen` 后记录在这里，避免 mousemove 高频重复请求。
    requestedDay: null,
    // 本周**已经拿到原生完整数据**的列（键 = 1…7）。
    //
    // ⚠️ 为什么不能拿 `panelDataFor()` 判断「有没有数据」（2026-11 修）：
    // 它有个「只有今日详情」的兜底，永远非空 → 补发请求的判断
    // 永远不成立 → 换周回来后跟随打开某列，只有农历、没有待办 / 日程，
    // 必须再点一下日期（走 onHeaderPick 无条件发请求）才更新
    // （用户反馈：「换到别的周再回到本周，待办不会第一时间显示」）。
    //
    // 原生会在待办 / 日程**查完并合并**后把 `ready` 置 true 再推过来，
    // 那才算这一列「有完整数据」。换周时整个清空（见 resetWeekCaches）。
    loaded: {},
    // **按天缓存**原生推来的 dayPanel 数据。
    //
    // 为什么要有：原生每次 push 状态都会触发一次 `render()`，而 `render()`
    // 以前会把整个 DOM 重建 —— 面板被摘掉又重建，入场动画重放，
    // 用户看到的就是「同一列上下移动时面板整块闪一下」。
    //
    // 缓存让「换列 / 淡出再回来」能**立刻**渲染出上一次拿到的数据，
    // 不用等原生下一次 push。
    //
    // ⚠️ 缓存 key 必须**绑定当前浏览周**（`S.viewWeek`）——
    // 翻周之后同一天的农历 / 节日都变了，用旧缓存会显示上一周的数据。
    cache: {},
    cacheWeek: null,
    // 原生「系统数据变了」的版本号（`dayPanelRevision`，2026-11）。
    //
    // 用户在系统「提醒事项」/「日历」里改了数据 → 原生重算红点后把这个
    // 数字加一。网页看到数字变了就**作废按天缓存**（见 ttUpdate 里的说明）。
    revision: null,
    // 点圆圈之后「正在完成」的待办（2026-11）。
    //
    // 用户要的交互：
    //   · 点空心圆 → 圆圈**立刻**变蓝，**其他都不变**；
    //   · 1 秒后整条待办**缓慢消失**。
    //
    // 但原生一旦把完成写回 EventKit，下一次推送里这条就**不在** `todos` 里了
    // —— 直接重绘会瞬间消失。所以这里按 identifier 暂存到计时结束，
    // 渲染时和原生数据合并：原生已经删掉的，继续显示。
    //
    // 键 → { todo, day, index, weekKey, phase, leaveTimer, removeTimer }
    pendingDone: {},
    // ⚠️ **7 天各自的「今日详情」**（2026-11 修）。
    //
    // 原生现在一次推 7 天（`dayFestivals`：键 = "1"…7"）。
    //
    // 以前只推当前那一天，网页换列时只能靠 `DP.cache[day]` 兜底 →
    //   · 刚打开某列时那一天的缓存还是空的 → **今日详情整块消失**
    //     （用户反馈「有的天数有、有的没有」）；
    //   · 指针扫到新列时先显示**上一列缓存的**内容 → **农历对不上**
    //     （用户反馈「今日详情大多数日期对不上」）。
    //
    // 现在每一天都有自己的一份，按 `day` 取，**永远不会串**。
    dayFestivals: {},
    // 入场动画（600ms clip-path 揭开）的**开始时刻**。
    //
    // 原生打开覆盖层后会立刻推一两次状态；`render()` 会把整张卡重建，
    // 覆盖层元素虽然被复用，但「摘下 → 挂回」这一下会**取消正在跑的
    // transition**（挂回时还被 `.dpnoreplay` 强制成终态）——
    // 用户看到的「瀑布还是唰一下就出来」就是动画被截断了。
    // 记住起点，render 之后按剩余时长**接着播**。
    openedAt: 0,
    // ⚠️ **课表正在被拖动**（2026-11 修「在表头往下滑，日历面板乱闪」）。
    //
    // 拖动课表时，窗口跟着鼠标移动 → 指针在**窗口里**的相对位置一直在变
    // → 网页的 `onPointerMove` 不断算出「不同的列」→ 跟随模式把面板
    // 一个接一个地打开 / 收起。
    //
    // 原生那边「拖动课表时会强制收起覆盖层」，两边一叠加就成了：
    // **突然出现 → 消失 → 渐渐出现**（用户反馈）。
    //
    // 拖动期间网页**完全不理指针移动**（不换列、不开关面板）——
    // 拖动和看详情本来就是互斥的两件事。
    dragging: false,
    // 「动画没跑」的兜底定时器句柄（2026-11 修「滑回表头时面板闪一下」）。
    //
    // ⚠️ 这个定时器**必须每次打开都取消上一次** ——
    // 否则上一次打开留下的定时器会在**这一次**打开的动画刚起步时触发，
    // 看到 clip-path 还在 100% 就判定「动画没跑」→ 加上 `.dpnoplay`
    // （= clip-path: none）→ **面板瞬间整个出现**（用户看到的「突然出现」），
    // 之后 `.dpnoplay` 被摘掉 → 揭开动画重播 → **「渐渐出现」**。
    //
    // 也就是用户说的「应该是要显示，但不是要这么闪一下」。
    openFallbackTimer: null,
    // 「收走过之后又要打开」—— 这个标志让 `openPanel` 知道
    // **要重新播一遍入场动画**（2026-11 修「滑回表头时面板闪一下」）。
    reopening: false,
    // ⚠️ **原生菜单开着**（2026-11 修「点删除时整个日历闪一下」）。
    //
    // 菜单是用一个临时的 NSPanel（level .floating）当宿主的 ——
    // 菜单一弹出，**指针就移到菜单上了**，而菜单在课表卡片的矩形之外。
    // 原生那边「指针是否在卡片上」的判定因此翻转 → 判定成「指针离开了课表」
    // → 原生发 `ttLiveHoverClear()` → 网页把**覆盖层收走**（用户看到「闪一下」）。
    //
    // 课程右键菜单从 1.0.x 起就有这个问题，但课表卡片本身不响应「指针离开」，
    // 所以看不出来；只有**日期覆盖层**会跟着收走。
    //
    // 原生在弹菜单前会置位、关闭后清位（见 MenuPresenter.onMenuVisibilityChanged）。
    // 这期间**任何**「指针离开」都不收覆盖层。
    menuOpen: false,
    // 菜单弹出时**正在看的那一列**（菜单期间指针可能移到别列，但用户要改的是这列）。
    menuDay: null,
    // 「跟随模式」是否开启。
    //
    // 面板**只能由点日期打开**（规格：触发 = 点表头日期格）。点开之后进入
    // 跟随模式：指针移到哪一列，面板就跟到哪一列；指针移出课表 / 移到时间列
    // 之类的非列区域会淡出，但**跟随模式还在** —— 移回来还会继续跟着出现。
    //
    // 再点一次当前列的日期 → 关闭并**退出跟随模式**：之后指针扫过任何日期
    // 都不会自己弹出来（想看就再点一次日期）。
    //
    // 之前把「面板可见」和「悬停可打开」混为一谈：只要面板淡出一次
    // （移出课表、移到时间列），悬停就再也打不开了 —— 用户实测反馈
    // 「点开后往下一移就没了，移回别的日期也没了」。
    following: false
  };

  // 窄态实心区的高度上限。
  // 不能写死 —— 窄态实心区的高度是**自适应**的（按内容高度定），
  // 真正的上限是「那一列还剩多少高度」（表头之下的整列高度）。
  // 下面这两个只是兜底（量不到高度时用）。
  // 实心区的**最小高度**（px）—— 内容少的时候至少这么高，
  // 免得面板只剩几行、下面全是空的渐变区。
  var DP_MIN_BODY = 216;
  var DP_NARROW_MAX = 240;   // 窄态实心区兜底上限
  // ⚠️ 宽态相关的常量（DP_WIDE_MAX / MIN / MAXW）已随宽态一起删掉
  // （2026-11 去掉双击展开）—— 覆盖层现在**只有一列宽**这一种形态。
  var DEFAULT_NARROW_TODOS = 4;  // 量不出高度时的兜底条数

  // ---- 数据 ----

  // 某天的红/橙点标记（来自原生 dayFlags）
  function dayFlagsOf(day) {
    var f = S && S.dayFlags;
    if (!f) return null;
    var v = f[String(day)];
    return v || null;
  }

  // 当前浏览周（缓存 key 的一部分）。
  //
  // 翻周之后同一天的农历 / 节气 / 节日**全都变了**，
  // 所以缓存必须按周隔离 —— 否则翻到下一周会显示上一周的农历。
  function viewWeekKey() {
    if (!S) return 'none';
    var w = (typeof S.viewWeek === 'number') ? S.viewWeek : null;
    return (w === null) ? 'all' : String(w);
  }

  // 换周（或进入 / 退出「全部周次」）→ **按周隔离**的状态一起作废。
  //
  // 缓存 / 「已请求」去重标记 / 「已拿到完整数据」的记录都只对
  // 当前浏览周有效 —— 换周后同一个「周几」已经是另一天，
  // 留着就会把上一周的状态错误地套到新一周上。
  function resetWeekCaches(key) {
    if (DP.cacheWeek === key) return;
    DP.cache = {};
    DP.cacheWeek = key;
    DP.requestedDay = null;
    DP.loaded = {};
    // 换周 = 另一批日期；正在编辑 / 刚保存待确认的那条都不再属于眼前这一列。
    if (DP.editingTodoKey || DP.pendingEdit) resetTodoEditState();
  }

  // 按天缓存原生推来的 dayPanel 数据。
  //
  // 「换列 / 淡出再回来」时先用缓存**立刻**渲染，
  // 等原生把新数据推过来再更新缓存。
  function cacheDayPanel(data) {
    if (!data || typeof data !== 'object') return;
    var d = (typeof data.day === 'number') ? data.day : null;
    if (d === null) return;
    resetWeekCaches(viewWeekKey());
    // ⚠️ **中间态（ready:false）不进缓存**（2026-11 修）。
    //
    // 原生的「打开某天」会先推一份只有节日、待办 / 日程为空的中间态。
    // 缓存它 = 下次打开这一天先用它渲染 → 面板先闪一下「今日无待办」，
    // 等 EventKit 回来才变成真实内容（用户反馈「点了日期先闪一下」）。
    // 中间态没有新信息（节日在 `dayFestivals` 里一直有），不缓存。
    if (data.ready === false) return;
    DP.cache[d] = data;
  }

  // 当前列的覆盖层数据（dayPanel）。
  //
  // 优先级：
  //   1. 原生推来的 `S.dayPanel`（对得上当前列时）—— 最新鲜；
  //   2. 按天缓存 `DP.cache[day]` —— 换列 / 淡出再回来时立刻能用；
  //   3. 都没有 → null。
  //
  // ⚠️ 以前这里对不上就返回 null → **整块内容（包括今日详情）全部消失**，
  // 一直等到下一次原生 push 到达才恢复。原生每次 push 都要先查 EventKit，
  // 有权限弹窗 / 查询耗时时就是好几秒的空白。
  function panelDataFor(day) {
    if (day === null || day === undefined) return null;
    var p = S && S.dayPanel;
    // 原生推的 dayPanel 只对应**当前打开的那天**；对不上就没有数据。
    if (p && typeof p === 'object' &&
        (typeof p.day !== 'number' || p.day === day)) {
      // ⚠️ **「今日详情」用这一天自己的那份**（2026-11）。
      //
      // `S.dayPanel` 里的 festival 是**当前那一天**的；
      // 但换列时网页可能先拿到**上一列**的内容 —— 农历就会对不上。
      // 所以这里拿 `dayFestivals[day]` 覆盖掉它（没有就保持原样）。
      var f = DP.dayFestivals[String(day)];
      // ⚠️ **原生推来的是「中间态」时，优先用这一天的完整缓存**（2026-11 修）。
      //
      // 中间态（ready:false）只有节日、待办 / 日程是空的。如果这一天之前
      // 已经拿到过完整数据，直接用它渲染 —— 否则每次点击日期都会先闪一下
      // 「今日无待办 / 今日无日程」，再跳成真实内容（用户反馈「头部会先闪一下」）。
      var base = p;
      if (p.ready === false) {
        var complete = DP.cache[day];
        if (complete && complete.ready !== false) {
          base = complete;
          // ⚠️ 日记是**本地数据**，不经过 EventKit —— 原生写完就推。
          // 而这里如果退回「完整缓存」，缓存里可能还没有刚写的那篇
          //（用户反馈「日记点了保存但是没有显示出来」）。
          // 所以：**新推来的 diary 永远以它为准**，覆盖缓存里的旧日记。
          if (p.diary && p.diary.length !== undefined) {
            var mergedBase = {};
            for (var kb in base) {
              if (Object.prototype.hasOwnProperty.call(base, kb)) mergedBase[kb] = base[kb];
            }
            mergedBase.diary = p.diary;
            base = mergedBase;
          }
        }
      }
      if (f && typeof f === 'object') {
        var merged = {};
        for (var k in base) {
          if (Object.prototype.hasOwnProperty.call(base, k)) merged[k] = base[k];
        }
        merged.festival = f;
        return merged;
      }
      return base;
    }
    // 对不上 → 退回到按天缓存（换周时缓存连带请求 / 已加载记录一起作废）。
    resetWeekCaches(viewWeekKey());
    var c = DP.cache[day];
    if (c && typeof c === 'object') {
      // 缓存里也补上这一天自己的「今日详情」。
      var f2 = DP.dayFestivals[String(day)];
      if (f2 && typeof f2 === 'object') {
        var merged2 = {};
        for (var k2 in c) {
          if (Object.prototype.hasOwnProperty.call(c, k2)) merged2[k2] = c[k2];
        }
        merged2.festival = f2;
        return merged2;
      }
      return c;
    }
    // ⚠️ **兜底：只有「今日详情」，没有待办 / 日程** ——
    //
    // 原生推的 7 天详情是**同步**跟着状态来的，所以即使 EventKit 还没回包，
    // 这一列的农历 / 节气 / 节日 / 宜忌也已经在了。
    //
    // 以前这里返回 null → **整块内容（包括今日详情）全部消失**。
    var f3 = DP.dayFestivals[String(day)];
    if (f3 && typeof f3 === 'object') {
      // ⚠️ `ready: false` 是**明确的「还没查完」**（不是「确实没有待办」）——
      // 待办 / 日程块会显示「读取中…」，避免先闪一下「今日无待办」。
      return { day: day, todos: [], events: [], festival: f3, ready: false };
    }
    return null;
  }

  // 这一天的待办 / 日程是否**还没查完**（原生明确说 ready=false）。
  //
  // 只有原生显式给的 false 才算 —— 自检 / 出图直接注入的数据没有这个字段，
  // 不能把它们当成「读取中」，否则自检里的内容会被占位符盖掉。
  function panelLoading(data) {
    return !!(data && data.ready === false);
  }

  // ---- 几何 ----

  // 「布局 → 屏幕」的额外倍率（原生在**缩小档位**用 CSS transform 缩放时设）。
  //
  // ⚠️ 为什么需要它（2026-11 加）：
  // WKWebView 的 `pageZoom` 在缩小档位会把**小字号**按 9pt 下限撑大
  // （`.wkdate` 9.5px 在 0.7 档被撑到 12.86px），卡片顶栏因此变高、
  // 整张卡片比例被改掉。所以缩小的档位改用 `body { transform: scale(s) }`：
  // 版式完全不变，只是整体视觉缩放。
  //
  // 副作用：`getBoundingClientRect()` 返回的已经是**乘过 transform 的视觉坐标**，
  // 而 `element.style.left/top/width/height` 仍按**布局坐标**解释。
  // 覆盖层要贴到列上，就必须把量出来的矩形除以这个倍率。
  // pageZoom 档位的视口坐标本身就是 CSS px，这一项为 1 → 不用除。
  function layoutScale() {
    var s = (typeof window.__ttGeomScale === 'number') ? window.__ttGeomScale : 1;
    return (s > 0 && s !== 1) ? s : 1;
  }

  // 找出某个列的表头格（.hcell[data-day]）
  function headerCellOf(day) {
    var cells = document.querySelectorAll('.hcell[data-day]');
    for (var i = 0; i < cells.length; i++) {
      if (parseInt(cells[i].getAttribute('data-day'), 10) === day) return cells[i];
    }
    return null;
  }

  // 网格几何：表头行底边、每列的 x/宽、网格总高
  //
  // 返回的是**布局坐标**（除以 `layoutScale()`），可以直接写进 style。
  function gridGeom() {
    var grid = DP.grid || document.querySelector('.grid');
    if (!grid) return null;
    var g = grid.getBoundingClientRect();
    var hdr = null;
    var cells = document.querySelectorAll('.hcell[data-day]');
    for (var i = 0; i < cells.length; i++) {
      if (parseInt(cells[i].getAttribute('data-day'), 10) === 1) { hdr = cells[i]; break; }
    }
    if (!hdr) return null;
    var hb = hdr.getBoundingClientRect();
    var s = layoutScale();
    return {
      grid: grid,
      rect: g,
      // 网格是 position:relative，覆盖层的坐标以它为原点
      headerBottom: (hb.bottom - g.top) / s,
      height: g.height / s
    };
  }

  // 某列在网格里的 x / 宽（布局坐标，同上）
  function columnGeom(day) {
    var cell = headerCellOf(day);
    if (!cell) return null;
    var g = DP.grid || document.querySelector('.grid');
    if (!g) return null;
    var gb = g.getBoundingClientRect();
    var cb = cell.getBoundingClientRect();
    var s = layoutScale();
    return {
      day: day,
      x: (cb.left - gb.left) / s,
      w: cb.width / s,
      left: (cb.left - gb.left) / s,
      right: (cb.right - gb.left) / s
    };
  }

  // 当前是不是「全部周次」模式。
  //
  // `S.viewWeek` 为 null = 全部周次（原生那边 `viewWeek == nil`）。
  function isAllWeeksMode() {
    return !(typeof S === 'object' && S !== null) ||
           !(typeof S.viewWeek === 'number');
  }

  // ---- 内容渲染 ----
  //
  // ⚠️ **卡片化**（2026-11 重做）：
  //
  // 以前是「三块分组标题 + 条目行」挤在一张玻璃面板里；
  // 现在改成**每条待办 / 每条日程 / 今日详情各自一张独立玻璃卡片**，
  // 卡片之间留 8–10px 间距，浮在一整块压暗磨砂底板上。
  //
  // 结构：
  //   .dpbody            压暗底板（外层，唯一带 backdrop-filter 的一层）
  //     .dpcards         卡片容器（纵向 flex，gap = 卡片间距）
  //       .dpcard        一张卡片（.todo / .event / .detail / .empty / .ghost）
  //         .dpcardhd    卡片标签行（小图标 + 类别名）
  //         .dpcardbody  卡片正文（标题 + 次要信息）
  //
  // 为什么底板**不透明到 1**：
  // 用户原话「下面的课程不会显示在上面，不然的话就看不清楚了」——
  // 我们背后是**彩色课表格**，不是参考图里的空背景，
  // 照抄参考图的透明度会让课表格直接透上来、和卡片文字叠在一起。
  // 所以底板保持 0.94 级别的不透明 + 40px 模糊，卡片自己的底色再压一层。

  // 一张卡片的标签行（图标 + 类别名）。
  function dpCardHead(icon, title, extra) {
    return h('div', { class: 'dpcardhd' },
      h('span', { class: 'dpcardicon', text: icon }),
      h('span', { class: 'dpcardlabel', text: title }),
      extra || null);
  }

  // 造一张卡片。
  //
  // `kind` 决定左侧竖条的颜色：
  //   todo   待办 → 青蓝
  //   event  日程 → 粉蓝
  //   detail 今日详情 → 紫青
  //   empty  空状态 → **无竖条**（更低调）
  //   ghost  「＋ 添加待办」→ 虚线幽灵卡
  function dpCard(kind, head, body, attrs) {
    var a = attrs || {};
    var node = h('div', {
      class: 'dpcard ' + kind + (a.className ? ' ' + a.className : '')
    });
    if (a.title) node.setAttribute('title', a.title);
    if (a.todoIndex !== undefined && a.todoIndex !== null) {
      node.setAttribute('data-todo-index', String(a.todoIndex));
    }
    if (a.todoKey) node.setAttribute('data-todo-key', a.todoKey);
    // 右键删除用：带上**系统 identifier**，原生就不用靠下标猜是哪一条
    //（下标依赖「网页和原生看到的是同一天、同一条列表」，跟随时会错位）。
    if (a.todoIdentifier) node.setAttribute('data-todo-identifier', a.todoIdentifier);
    if (a.todoCalendar) node.setAttribute('data-todo-calendar', a.todoCalendar);
    // ⚠️ **稳定键**：重绘时靠它判断「这张卡片还是不是同一张」
    // （见 renderPanel 里的 syncCards）。没有键的卡片每次都会重建。
    if (a.nodeKey) node.setAttribute('data-node-key', a.nodeKey);
    if (a.onclick) node.addEventListener('click', a.onclick);
    if (head) node.appendChild(head);
    if (body) node.appendChild(body);
    return node;
  }

  // 「正在完成」这条待办的稳定键：优先用系统 identifier，
  // 没有（老数据 / 自检注入）就退回标题 + 到期时间。
  function todoKeyOf(t) {
    if (t && t.identifier) return 'id:' + String(t.identifier);
    return 't:' + String((t && t.title) || '') + '|' + String((t && t.due) || '');
  }

  function findTodoCard(key) {
    var cards = document.querySelectorAll('.dpcard.todo');
    for (var i = 0; i < cards.length; i++) {
      if (cards[i].getAttribute('data-todo-key') === key) return cards[i];
    }
    return null;
  }

  // ---- 待办编辑 / 时间输入（2026-11）----

  // 一条待办是不是这一条（优先 identifier，老数据才退回稳定键）。
  function todoMatches(t, key, identifier) {
    if (!t) return false;
    if (identifier && t.identifier === identifier) return true;
    return !!(key && todoKeyOf(t) === key);
  }

  // 按稳定键从**当前显示的数据**里找一条待办（返回原始下标）。
  function findTodoByKey(day, key) {
    var data = panelDataFor(day);
    var todos = (data && data.todos) || [];
    for (var i = 0; i < todos.length; i++) {
      if (todoKeyOf(todos[i]) === key) return { t: todos[i], i: i };
    }
    return null;
  }

  function pad2(n) {
    n = parseInt(n, 10);
    if (isNaN(n)) return '';
    return n < 10 ? '0' + n : '' + n;
  }

  // 单个时 / 分输入框的**失焦整理**：一位数补成两位，非法返回 null。
  //
  // ⚠️ 空框**保持空**（不补成 00）—— 用户主动清空时不要偷偷改回 00，
  // 保存时按 00 处理就行（见 `parseTodoTimeParts`）。
  function normalizeTimePart(value) {
    var s = String(value == null ? '' : value).trim();
    if (!s) return '';
    if (!/^\d{1,2}$/.test(s)) return null;
    return pad2(parseInt(s, 10));
  }

  // 一个完整的 `HH:mm` 文本（支持 `9:5` / `2000` / `09:05`）。
  // 非法返回 null；空返回 null（调用方自己决定空 = 00:00）。
  function parseTodoTimeText(raw) {
    var s = String(raw == null ? '' : raw).trim();
    if (!s) return null;
    var m = /^(\d{1,2}):(\d{1,2})$/.exec(s);
    var hour;
    var minute;
    if (m) {
      hour = m[1];
      minute = m[2];
    } else {
      var digits = s.replace(/\D/g, '');
      if (!digits || digits.length > 4) return null;
      if (digits.length <= 2) {
        hour = digits;
        minute = '0';
      } else {
        hour = digits.slice(0, -2);
        minute = digits.slice(-2);
      }
    }
    if (!/^\d{1,2}$/.test(hour) || !/^\d{1,2}$/.test(minute)) return null;
    var h = parseInt(hour, 10);
    var mm = parseInt(minute, 10);
    if (isNaN(h) || isNaN(mm) || h < 0 || h > 23 || mm < 0 || mm > 59) return null;
    return {
      hour: pad2(h),
      minute: pad2(mm),
      text: pad2(h) + ':' + pad2(mm),
      minutes: h * 60 + mm
    };
  }

  // 时 / 分两个框合起来解析；两个都空 = 00:00（和添加的默认行为一致）。
  function parseTodoTimeParts(hourRaw, minuteRaw) {
    var h = String(hourRaw == null ? '' : hourRaw).trim();
    var m = String(minuteRaw == null ? '' : minuteRaw).trim();
    if (!h) h = '0';
    if (!m) m = '0';
    if (!/^\d{1,2}$/.test(h) || !/^\d{1,2}$/.test(m)) return null;
    var hh = parseInt(h, 10);
    var mm = parseInt(m, 10);
    if (isNaN(hh) || isNaN(mm) || hh < 0 || hh > 23 || mm < 0 || mm > 59) return null;
    return {
      hour: pad2(hh),
      minute: pad2(mm),
      text: pad2(hh) + ':' + pad2(mm),
      minutes: hh * 60 + mm
    };
  }

  // `due` 字符串 → 两个输入框的初值（拿不到就给空，调用方按 00:00 兜底）。
  function splitTodoTime(due) {
    var p = parseTodoTimeText(due);
    if (!p) return { hour: '', minute: '' };
    return { hour: p.hour, minute: p.minute };
  }

  // 排序口径和原生 `--verify` / EventKitStore 一致：时刻 → 标题。
  function todoDueMinutesOf(t) {
    var p = parseTodoTimeText(t && t.due);
    return p ? p.minutes : 1440;
  }
  function sortTodoList(list) {
    if (!Array.isArray(list)) return;
    list.sort(function (a, b) {
      var am = todoDueMinutesOf(a);
      var bm = todoDueMinutesOf(b);
      if (am !== bm) return am - bm;
      var at = String((a && a.title) || '');
      var bt = String((b && b.title) || '');
      return at < bt ? -1 : (at > bt ? 1 : 0);
    });
  }

  // 把某一条的标题 / 时间改到本地数据里（乐观展示用）。
  //
  // ⚠️ 必须同时改 `S.dayPanel` 和按天缓存：`panelDataFor()` 优先读 S，
  // 换列 / 淡出回来读缓存 —— 只改一份的话，另一个入口会拿到旧值。
  function patchTodoEverywhere(day, key, identifier, title, due) {
    var panels = [];
    if (S && S.dayPanel && typeof S.dayPanel === 'object') {
      if (typeof S.dayPanel.day !== 'number' || S.dayPanel.day === day) panels.push(S.dayPanel);
    }
    if (DP.cache && DP.cache[day] && DP.cache[day] !== (S && S.dayPanel)) {
      panels.push(DP.cache[day]);
    }
    for (var pi = 0; pi < panels.length; pi++) {
      var p = panels[pi];
      var todos = (p && p.todos) || [];
      var changed = false;
      for (var i = 0; i < todos.length; i++) {
        if (todoMatches(todos[i], key, identifier)) {
          todos[i].title = title;
          todos[i].due = due;
          changed = true;
        }
      }
      if (changed) sortTodoList(todos);
    }
  }

  function timeInputsOf(kind) {
    if (kind === 'add') return { hour: DP.timeHour, minute: DP.timeMinute };
    return { hour: DP.editHour, minute: DP.editMinute };
  }

  function timeValueOf(kind, part) {
    if (kind === 'add') return part === 'hour' ? DP.timeHourValue : DP.timeMinuteValue;
    return part === 'hour' ? DP.editHourValue : DP.editMinuteValue;
  }

  function setTimeValue(kind, part, value) {
    if (kind === 'add') {
      if (part === 'hour') DP.timeHourValue = value; else DP.timeMinuteValue = value;
    } else {
      if (part === 'hour') DP.editHourValue = value; else DP.editMinuteValue = value;
    }
  }

  function setTimeInputs(kind, hour, minute) {
    var t = timeInputsOf(kind);
    setTimeValue(kind, 'hour', hour);
    setTimeValue(kind, 'minute', minute);
    if (t.hour) t.hour.value = hour;
    if (t.minute) t.minute.value = minute;
  }

  function focusTimePart(kind, part) {
    var t = timeInputsOf(kind);
    var el = part === 'hour' ? t.hour : t.minute;
    if (el) {
      try { el.focus(); el.select(); } catch (e) {}
    }
  }

  // 键盘 ±1 调整一个时 / 分框（**到头循环**）。
  //
  // · 时：00 ↔ 23；分：00 ↔ 59；
  // · 框是空的 → 按 ↑ 变成 `01`（按 ↓ 变成 `00`），
  //   「空」先当成 0 再加，比「空 + 1」更符合直觉。
  //
  // 口径和「课程时间自定义」（PeriodTimesEditor）一致：
  // 那个组件也是分 / 时各一个框、失焦补零、上下键加减。
  function stepTimePart(kind, part, delta) {
    var isHour = part === 'hour';
    var max = isHour ? 23 : 59;
    var raw = timeValueOf(kind, part);
    var current = /^\d{1,2}$/.test(String(raw || '').trim())
      ? parseInt(String(raw).trim(), 10)
      : 0;
    if (isNaN(current)) current = 0;
    var next = current + delta;
    // 到头就循环（00 → 23 / 59；23 / 59 → 00）。
    if (next > max) next = 0;
    if (next < 0) next = max;
    var text = pad2(next);
    setTimeValue(kind, part, text);
    var t = timeInputsOf(kind);
    var el = isHour ? t.hour : t.minute;
    if (el) {
      el.value = text;
      // 数字变了，把光标放到末尾（否则会出现「20」按↑变「21」但光标还在中间）。
      try {
        el.focus();
        if (el.setSelectionRange) el.setSelectionRange(text.length, text.length);
      } catch (e) {}
    }
    return text;
  }

  // 离开输入区（不是切到同一个表单里的另一个框）且时间非法 → 就地提示。
  //
  // 用 `setTimeout(0)`：点「添加 / 保存」时先跑完 click，再决定要不要提示；
  // 如果点击已经成功提交（表单关了），这里什么都不做。
  function scheduleTimeBlurValidation(kind) {
    setTimeout(function () {
      if (kind === 'add' && !DP.adding) return;
      if (kind === 'edit' && !DP.editingTodoKey) return;
      var active = document.activeElement;
      // ⚠️ **类名要对**（2026-11-09 修）。
      //
      // 以前写的是 `.dpinput`，但添加态表单的根类其实是 **`.dpaddform`**
      // （`.dpinputrow` 只是里面那一行的类）—— 选择器**永远匹配不上**，
      // 于是「用户还在表单里」这个判断从来没成立过：
      // 从时框点到分框（焦点还在表单里）也会被判成「离开了输入区」→
      // 时间非法时就地弹红字。
      var formSelector = kind === 'add' ? '.dpaddform' : '.dpedit';
      if (active && active.closest && active.closest(formSelector)) return;
      var parts = kind === 'add'
        ? parseTodoTimeParts(DP.timeHourValue, DP.timeMinuteValue)
        : parseTodoTimeParts(DP.editHourValue, DP.editMinuteValue);
      if (parts) return;
      if (kind === 'add') DP.addError = '时间请用 00:00–23:59';
      else DP.editError = '时间请用 00:00–23:59';
      if (DP.open && DP.day !== null) {
        renderPanel();
        applyNarrowLimit();
        positionPanel();
      }
    }, 0);
  }

  // 拿到（必要时创建）一个时 / 分输入框。**只创建一次**，之后跨重绘复用。
  function ensureTimePart(kind, part) {
    var existing = timeInputsOf(kind)[part];
    if (existing) return existing;
    var isHour = part === 'hour';
    var input = h('input', {
      type: 'text',
      class: 'dptimepart',
      placeholder: isHour ? 'HH' : 'MM',
      inputmode: 'numeric',
      autocomplete: 'off',
      spellcheck: 'false',
      'data-dp-time-part': kind + '-' + part,
      // ⚠️ 卡片上的点击是原生**合成**转发的（`dispatchEvent(new MouseEvent('click'))`），
      // 合成点击**不会自动聚焦**输入框 —— 以前点上去没光标、打字自然没反应。
      // 这里显式聚焦 + 全选（打字直接覆盖两位数字），并顺带进入文本输入模式。
      onclick: function (e) {
        // ⚠️ **别让点击冒泡到「添加待办」那张卡**（2026-11-09 修）。
        // 冒泡过去会被当成「点标签 = 重新打开输入框」→ 面板整个重建
        // → 待办卡片被换掉（看起来消失）+ 时 / 分框失焦 → 键盘断掉。
        if (e && e.stopPropagation) e.stopPropagation();
        try { input.focus(); input.select(); } catch (e) {}
        if (typeof window !== 'undefined' && window.__ttCardLog) {
          try { window.__ttCardLog.push('onclick focus 后 active=' +
            (document.activeElement ? (document.activeElement.getAttribute('data-dp-time-part') ||
             document.activeElement.getAttribute('data-dp-input') ||
             (document.activeElement.className || document.activeElement.tagName)) : 'none') +
            '@' + Math.round(performance.now())); } catch (e) {}
        }
        post('textInputFocus', {});
      },
      onfocus: function () {
        post('textInputFocus', {});
      },
      onblur: function () {
        // 失焦只做「补零」；非法值等提交 / 真正离开输入区时再提示。
        var normalized = normalizeTimePart(input.value);
        if (normalized !== null) {
          input.value = normalized;
          setTimeValue(kind, part, normalized);
        }
        // ⚠️ **焦点还在同一个表单里 → 不要退出文本输入模式**（2026-11-09 修）。
        //
        // 时框 → 分框 会先 blur 时框；以前这里无条件 `post('textInputBlur')`
        // → 原生把键盘收走 → 分框打不了字（「时间输入还是有问题」）。
        //
        // 焦点落在**下一个框**上要等下一帧才知道，所以晚一拍再判断。
        var root = input.closest ? input.closest(kind === 'add' ? '.dpaddform' : '.dpedit') : null;
        setTimeout(function () {
          if (focusStillInside(root, input)) return;
          post('textInputBlur', {});
          scheduleTimeBlurValidation(kind);
        }, 0);
      },
      oninput: function () {
        // 用户开始改时间 → 上一次的红色提示立刻撤掉。
        if (typeof clearAddError === 'function') clearAddError();
        var raw = input.value;
        // 粘贴 `20:00` / `2000` / `9:5`：一次把两个框都填好。
        if (raw.indexOf(':') >= 0 || raw.replace(/\D/g, '').length > 2) {
          var parsed = parseTodoTimeText(raw);
          if (parsed) {
            setTimeInputs(kind, parsed.hour, parsed.minute);
            focusTimePart(kind, 'minute');
            return;
          }
          // 输入了「9:」这种半成品：冒号不用真的敲，把 9 留在时框、跳到分框。
          if (raw.indexOf(':') >= 0) {
            var beforeColon = raw.split(':')[0].replace(/\D/g, '').slice(0, 2);
            if (beforeColon) {
              input.value = beforeColon;
              setTimeValue(kind, part, beforeColon);
              focusTimePart(kind, 'minute');
              return;
            }
          }
        }
        var digits = raw.replace(/\D/g, '').slice(0, 2);
        if (digits !== raw) input.value = digits;
        setTimeValue(kind, part, digits);
        // 填满两位 → 自动跳到下一个框：
        //   时 → 分；分 → 时（回到开头继续调）。
        // 和「课程时间自定义」的手感一致。
        if (digits.length === 2) {
          focusTimePart(kind, isHour ? 'minute' : 'hour');
        }
      },
      onkeydown: function (e) {
        e.stopPropagation();
        var t = timeInputsOf(kind);
        var other = isHour ? t.minute : t.hour;
        if (e.key === 'Enter' || e.keyCode === 13) {
          if (kind === 'add') commitTodo(DP.day, DP.input);
          else commitTodoEdit();
        } else if (e.key === 'Escape' || e.keyCode === 27) {
          if (kind === 'add') closeTodoCompose();
          else cancelTodoEdit();
        } else if (e.key === 'ArrowUp' || e.keyCode === 38) {
          // ↑ 加 1（到头循环）；框是空的 → 变成 01。
          e.preventDefault();
          stepTimePart(kind, part, 1);
        } else if (e.key === 'ArrowDown' || e.keyCode === 40) {
          // ↓ 减 1（到头循环）。
          e.preventDefault();
          stepTimePart(kind, part, -1);
        } else if (e.key === 'ArrowLeft' || e.keyCode === 37) {
          // ← 跳到「时」；→ 跳到「分」（用户要求：左右键切换时 / 分）。
          e.preventDefault();
          focusTimePart(kind, 'hour');
        } else if (e.key === 'ArrowRight' || e.keyCode === 39) {
          e.preventDefault();
          focusTimePart(kind, 'minute');
        } else if ((e.key === 'Backspace' || e.keyCode === 8) && !input.value && other) {
          other.focus();
        } else if (e.key === 'Tab' && !e.shiftKey && isHour && other) {
          e.preventDefault();
          other.focus();
        }
      }
    });
    if (kind === 'add') {
      if (part === 'hour') DP.timeHour = input; else DP.timeMinute = input;
      // ⚠️ **默认显示 `00`**（四个 0）—— 和「课程时间自定义」里
      // 时 / 分两个框的观感一致，用户一眼就知道这里能填时间。
      input.value = timeValueOf(kind, part) || '00';
    } else {
      if (part === 'hour') DP.editHour = input; else DP.editMinute = input;
      input.value = timeValueOf(kind, part) || '00';
    }
    return input;
  }

  function ensureEditTitleInput() {
    if (DP.editTitle) return DP.editTitle;
    var input = h('input', {
      type: 'text',
      class: 'dpedittitle',
      placeholder: '待办标题',
      maxlength: '80',
      'data-dp-edit-title': '1',
      onfocus: function () {
        post('textInputFocus', {});
      },
      onblur: function () {
        // ⚠️ 焦点还在同一个表单里 → 不要退出文本输入模式（2026-11-09 修）。
        var root = input.closest ? input.closest('.dpedit') : null;
        setTimeout(function () {
          if (focusStillInside(root, input)) return;
          post('textInputBlur', {});
        }, 0);
      },
      oninput: function () {
        DP.editTitleValue = input.value;
      },
      onkeydown: function (e) {
        e.stopPropagation();
        if (e.key === 'Enter' || e.keyCode === 13) commitTodoEdit();
        else if (e.key === 'Escape' || e.keyCode === 27) cancelTodoEdit();
      }
    });
    DP.editTitle = input;
    return input;
  }

  // 退出编辑态（不动数据）。
  function resetTodoEditState() {
    DP.editingTodoKey = null;
    DP.editError = '';
    DP.editFocusPending = false;
    DP.editFocusRequested = false;
    DP.pendingEdit = null;
    DP.editTitleValue = '';
    DP.editHourValue = '';
    DP.editMinuteValue = '';
  }

  // 进入编辑态：在原待办卡片里就地把标题 / 时间换掉。
  function beginTodoEdit(key) {
    if (!key) return false;
    // ⚠️ **面板已经被收走时，把它带回来**（2026-11）。
    //
    // 菜单期间指针会离开卡片 → 原生判定「指针离开」→ 覆盖层被收走
    // （`DP.open == false`、`DP.day == null`）。这时用户选「修改…」，
    // 如果直接 return false 就**什么都没发生**（用户以为菜单坏了）。
    //
    // 这里按「菜单打开时记住的那一列」重新打开，再进入编辑态。
    var targetDay = DP.menuDay !== null ? DP.menuDay : DP.day;
    if (!DP.open || DP.day === null) {
      if (targetDay === null || targetDay === undefined) return false;
      DP.following = true;
      openPanel(targetDay);
    }
    var found = findTodoByKey(DP.day, key);
    if (!found) return false;
    if (DP.editingTodoKey === key) {
      DP.editFocusPending = false;
      setTimeout(function () { try { DP.editTitle.focus(); } catch (e) {} }, 0);
      return true;
    }
    DP.adding = false;      // 两个表单不能同时开着
    DP.addError = '';
    DP.pendingEdit = null;
    DP.editingTodoKey = key;
    DP.editTitleValue = found.t.title || '';
    var parts = splitTodoTime(found.t.due);
    DP.editHourValue = parts.hour || '00';
    DP.editMinuteValue = parts.minute || '00';
    DP.editError = '';
    DP.editFocusPending = true;
    DP.editFocusRequested = false;
    renderPanel();
    applyNarrowLimit();
    positionPanel();
    return true;
  }

  function cancelTodoEdit() {
    if (!DP.editingTodoKey) return;
    resetTodoEditState();
    post('textInputBlur', {});
    renderPanel();
    applyNarrowLimit();
    positionPanel();
  }

  // 保存编辑：标题不能空、时间必须 00:00–23:59；非法就地提示、不提交。
  function commitTodoEdit() {
    var key = DP.editingTodoKey;
    if (!key || DP.day === null) return;
    var found = findTodoByKey(DP.day, key);
    if (!found) {
      resetTodoEditState();
      renderPanel();
      return;
    }
    var title = String(DP.editTitleValue || '').trim();
    if (!title) {
      DP.editError = '标题不能为空';
      DP.editFocusPending = true;
      renderPanel();
      applyNarrowLimit();
      return;
    }
    var parts = parseTodoTimeParts(DP.editHourValue, DP.editMinuteValue);
    if (!parts) {
      DP.editError = '时间请用 00:00–23:59';
      renderPanel();
      applyNarrowLimit();
      setTimeout(function () { focusTimePart('edit', 'hour'); }, 0);
      return;
    }
    var todo = found.t;
    if (!todo.identifier) {
      DP.editError = '这条待办没有系统标识，无法修改';
      renderPanel();
      applyNarrowLimit();
      return;
    }
    var day = DP.day;
    // 先记下「保存后应该长什么样」——原生回包之前，晚到的旧快照会被它盖住。
    DP.pendingEdit = {
      key: key,
      identifier: todo.identifier,
      day: day,
      title: title,
      time: parts.text,
      oldTitle: todo.title || '',
      oldDue: todo.due || ''
    };
    post('todoUpdate', {
      day: day,
      identifier: todo.identifier,
      calendarIdentifier: todo.calendarIdentifier || '',
      title: title,
      time: parts.text,
      // 兼容老原生 / 自检：仍然带上下标。
      index: (typeof found.i === 'number') ? found.i : -1
    });
    // 乐观展示：立刻把卡片换成新标题 / 新时间。
    patchTodoEverywhere(day, key, todo.identifier, title, parts.text);
    DP.editingTodoKey = null;
    DP.editError = '';
    DP.editFocusPending = false;
    DP.editTitleValue = '';
    DP.editHourValue = '';
    DP.editMinuteValue = '';
    DP.addError = '';
    post('textInputBlur', {});
    renderPanel();
    applyNarrowLimit();
    positionPanel();
  }

  // 右键菜单里的「删除」→ 立刻播现有的淡出动画，再走原来的 todoDelete。
  //
  // ⚠️ 和「完成」共用 `DP.pendingDone` 的展示期机制：原生写回 / 取数期间
  // 旧数据里可能还带着这条，pending 让它继续淡出、不「复活」一下。
  function startTodoDelete(day, todo, index, key) {
    if (!todo || DP.pendingDone[key]) return;
    if (DP.editingTodoKey === key) resetTodoEditState();
    if (DP.pendingEdit && DP.pendingEdit.key === key) DP.pendingEdit = null;
    var entry = {
      todo: {
        title: todo.title || '',
        due: todo.due || '',
        done: false,
        identifier: todo.identifier || '',
        calendarIdentifier: todo.calendarIdentifier || ''
      },
      day: day,
      index: (typeof index === 'number') ? index : 0,
      weekKey: viewWeekKey(),
      phase: 'leaving',
      deleting: true,
      leaveAt: nowMs(),
      leaveTimer: null,
      removeTimer: null,
      giveUpTimer: null
    };
    DP.pendingDone[key] = entry;
    var card = findTodoCard(key);
    if (card) card.classList.add('leaving');
    post('todoDelete', {
      day: day,
      index: (typeof index === 'number') ? index : -1,
      identifier: todo.identifier || '',
      calendarIdentifier: todo.calendarIdentifier || ''
    });
    entry.removeTimer = setTimeout(function () {
      if (DP.pendingDone[key] !== entry) return;
      entry.phase = 'gone';
      // 写回失败（原生一直推回这条）→ 5 秒后恢复显示，别让条目永远消失。
      entry.giveUpTimer = setTimeout(function () {
        if (DP.pendingDone[key] !== entry) return;
        delete DP.pendingDone[key];
        renderPanel();
        applyNarrowLimit();
        positionPanel();
      }, 5000);
      renderPanel();
      applyNarrowLimit();
      positionPanel();
    }, DP_LEAVE_MS);
  }

  function deleteTodoByKey(key, info) {
    if (!key) return false;
    var found = findTodoByKey(DP.day, key);
    var todo;
    var index = 0;
    if (found) {
      todo = found.t;
      index = found.i;
    } else {
      todo = {
        title: (info && info.title) || '',
        due: (info && info.due) || '',
        identifier: (info && info.identifier) || '',
        calendarIdentifier: (info && info.calendarIdentifier) || ''
      };
      index = (info && typeof info.index === 'number') ? info.index : 0;
    }
    startTodoDelete(DP.day, todo, index, key);
    return true;
  }

  // 原生菜单选完之后的回调（修改 / 删除）。
  window.ttDayPanelTodoMenuAction = function (action, info) {
    info = info || {};
    var key = info.key || '';
    if (!key && info.identifier && DP.day !== null) {
      var data = panelDataFor(DP.day);
      var todos = (data && data.todos) || [];
      for (var i = 0; i < todos.length; i++) {
        if (todos[i].identifier === info.identifier) {
          key = todoKeyOf(todos[i]);
          break;
        }
      }
    }
    if (!key) return false;
    if (action === 'edit') return beginTodoEdit(key);
    if (action === 'delete') return deleteTodoByKey(key, info);
    return false;
  };

  // 自检用：编辑态的诊断（隐藏页面里 activeElement 不一定拿得到）。
  window.ttDayPanelTodoState = function () {
    return {
      editingKey: DP.editingTodoKey,
      focusPending: DP.editFocusPending,
      focusRequested: DP.editFocusRequested,
      hasTitleInput: !!(DP.editTitle && DP.editTitle.parentNode),
      pendingEdit: DP.pendingEdit ? DP.pendingEdit.title : null
    };
  };

  // 原生写完「修改」之后回报结果：失败就回滚 + 提示，成功就等推送确认。
  window.ttDayPanelTodoUpdateResult = function (res) {
    if (!res || typeof res !== 'object') return;
    var pe = DP.pendingEdit;
    if (!pe) {
      if (!res.ok) {
        DP.addError = res.message || '修改失败';
        if (DP.open && DP.day !== null) {
          renderPanel();
          applyNarrowLimit();
          positionPanel();
        }
      }
      return;
    }
    if (!res.ok) {
      // 写回失败 → 把本地乐观改掉的值还原，并显示原因。
      patchTodoEverywhere(pe.day, pe.key, pe.identifier, pe.oldTitle, pe.oldDue);
      DP.addError = res.message || '修改失败';
    } else {
      // 成功：继续用这份乐观值撑到原生推送到达（防止晚到的旧快照闪回）。
      patchTodoEverywhere(pe.day, pe.key, pe.identifier, pe.title, pe.time);
    }
    DP.pendingEdit = null;
    if (DP.open && DP.day !== null) {
      renderPanel();
      applyNarrowLimit();
      positionPanel();
    }
  };

  // 点圆圈 = 完成。**只有圆圈能触发**（2026-11 用户确认）：
  //   · 立刻把圆圈变蓝，**不重绘整块面板**（标题、间距都不动）；
  //   · 1 秒后加 `.leaving` → 缓慢淡出（400ms）→ 移除。
  //
  // 原生仍是唯一的数据源：这里只发 `todoToggle`，完成写回后原生会推来
  // 不含这条的新内容；`pendingDone` 让它在这 1.4 秒里继续留在界面上。
  //
  // ⚠️ 1.4 秒之后记录不会立刻丢（转成 `gone`），因为原生重取数可能还没回来
  // —— 否则重绘会用旧数据把它画回来（2026-11 修）。
  function startTodoComplete(day, todo, index, key) {
    if (!todo || DP.pendingDone[key]) return;
    var entry = {
      todo: {
        title: todo.title || '',
        due: todo.due || '',
        done: true,
        identifier: todo.identifier || '',
        calendarIdentifier: todo.calendarIdentifier || ''
      },
      day: day,
      // 原来在列表里的位置 —— 原生删掉它之后，按这个位置补回去，
      // 免得它在消失前突然跳到列表末尾（「其他的都不要变」）。
      index: (typeof index === 'number') ? index : 0,
      weekKey: viewWeekKey(),
      phase: 'done',
      // 开始淡出的时刻（`phase` 变成 'leaving' 时记下）。
      //
      // ⚠️ 重绘时要靠它**接着**淡出（见 dpTodoSection 里的负 delay），
      // 不能从 opacity:1 重头播 —— 否则原生推送一大，正在淡的条目
      // 会「消失一下又弹回来」（2026-11 修）。
      leaveAt: 0,
      leaveTimer: null,
      removeTimer: null,
      giveUpTimer: null
    };
    DP.pendingDone[key] = entry;

    // ⚠️ 直接改现有卡片，**不要 renderPanel()**：
    // 重绘会重建整块内容，用户会看到面板闪一下。
    // 这里只有圆圈变蓝，其它节点一个都不动。
    var card = findTodoCard(key);
    if (card) card.classList.add('completing');

    post('todoToggle', {
      day: day,
      identifier: todo.identifier || '',
      calendarIdentifier: todo.calendarIdentifier || '',
      // 兼容老版本原生（也方便自检）：仍然带上原始下标。
      index: (typeof index === 'number') ? index : -1
    });

    // 1 秒：开始消失（缓慢淡出 400ms）。
    entry.leaveTimer = setTimeout(function () {
      entry.phase = 'leaving';
      entry.leaveAt = nowMs();
      var el = findTodoCard(key);
      if (el) el.classList.add('leaving');
    }, 1000);

    // 1 秒 + 消失动画跑完：**视觉上**移除。
    //
    // ⚠️ **不能在这里直接丢掉记录**（2026-11 修）。
    //
    // 原生「完成写回 + 重新取数」是异步的：1.4 秒时 `S.dayPanel` 里
    // 可能**还带着这条**（done=false）—— 直接删记录再重绘，就会把旧数据
    // 里的同一条又画回来，等原生最终推送才消失
    //（用户反馈「消失以后马上又回来」）。
    //
    // 所以先转成 `gone`：渲染时继续隐藏它，等原生数据里确实没有这条了，
    // dpTodoSection 才会把记录真正删掉。
    entry.removeTimer = setTimeout(function () {
      if (DP.pendingDone[key] !== entry) return;
      entry.phase = 'gone';
      // 兜底：万一写回失败（原生一直推回这条），不能让它「永远消失」——
      // 5 秒后恢复显示。
      entry.giveUpTimer = setTimeout(function () {
        if (DP.pendingDone[key] !== entry) return;
        delete DP.pendingDone[key];
        renderPanel();
        applyNarrowLimit();
        positionPanel();
      }, 5000);
      renderPanel();
      applyNarrowLimit();
      positionPanel();
    }, 1400);
  }

  // 待办块：**每条待办一张卡片** + 永远存在的「＋ 添加待办」幽灵卡。
  function dpTodoSection(data, day) {
    var todos = (data && data.todos) || [];
    // 「今天 N 条待处理 · 逾期 M 条」（2026-11-10，仅今天那一列）。
    var digest = (data && data.isToday && data.todoDigest) ? data.todoDigest : null;
    var digestLine = null;
    if (digest && ((digest.today || 0) + (digest.overdue || 0)) > 0) {
      var parts = [];
      if (digest.today > 0) parts.push('今天 ' + digest.today + ' 条待处理');
      if (digest.overdue > 0) parts.push('逾期 ' + digest.overdue + ' 条');
      digestLine = h('div', { class: 'dpdigest', text: parts.join(' · ') });
    }

    // **已完成的不显示** —— 做完了的事不该还占着位置。
    //
    // 索引要保留**原始下标**：`todoToggle` 回传的是原生那边的下标，
    // 这里过滤掉已完成项后下标就错位了，勾到的会是另一条。
    //
    // ⚠️ 原生现在已经把已完成的待办过滤掉了（`visibleTodos`），
    // 这里保留 `!t.done` 这道判断是给缓存 / 老数据兜底。
    var open = [];
    var seen = {};
    todos.forEach(function (t, i) {
      if (t.done) return;
      var key = todoKeyOf(t);
      var pending = DP.pendingDone[key] || null;
      // ⚠️ **视觉上已经消失、但原生数据还没更新**的条目：继续隐藏。
      //
      // 1.4 秒后完成动画已经放完，可原生那次重取数可能还没回来 ——
      // `todos` 里仍然是这条 done=false。照常渲染就会让它「又回来」
      //（用户反馈「消失以后马上又回来」）。
      // 标记 seen，防止下面按「原生已删除」再补回来。
      if (pending && pending.phase === 'gone') {
        seen[key] = true;
        return;
      }
      open.push({ t: t, i: i, key: key, pending: pending });
      seen[key] = true;
    });

    // 原生已经把它从 `todos` 里删掉了（完成写回成功）——
    // 只要还在展示期内，就按**原来的位置**补回去。
    var missing = [];
    Object.keys(DP.pendingDone).forEach(function (key) {
      var p = DP.pendingDone[key];
      if (!p || seen[key]) return;
      if (p.day !== day || p.weekKey !== viewWeekKey()) return;
      // `gone` 且数据里确实没有它 = 原生确认完成 → 视觉移除完成，忘掉记录。
      if (p.phase === 'gone') {
        if (p.giveUpTimer) clearTimeout(p.giveUpTimer);
        delete DP.pendingDone[key];
        return;
      }
      missing.push({ key: key, p: p });
    });
    missing.sort(function (a, b) { return a.p.index - b.p.index; });
    missing.forEach(function (m) {
      var at = Math.min(Math.max(m.p.index, 0), open.length);
      open.splice(at, 0, { t: m.p.todo, i: null, key: m.key, pending: m.p });
    });

    var out = [];
    // 摘要单独一张细卡片（仅今天、且有未处理 / 逾期时）。
    if (digestLine) {
      out.push(dpCard('digest', null, digestLine, { nodeKey: 'todo-digest' }));
    }
    if (!open.length) {
      // 空状态：**一张低调的卡片**（没有彩色竖条）。
      // 分类不能整块消失 —— 用户要一眼看到「今天没有待办」这件事。
      //
      // ⚠️ 数据还没查完时不能说「今日无待办」（那是在撒谎，而且马上会被
      // 真实内容替换 → 用户看到的就是闪一下）。显示「读取中…」占位。
      var todoLoading = panelLoading(data);
      out.push(dpCard('empty',
        dpCardHead('📋', '待办事项'),
        h('div', { class: 'dpempty' + (todoLoading ? ' dploading' : ''),
                   text: todoLoading ? '读取中…' : '今日无待办' }),
        { nodeKey: 'todo-empty' }));
    } else {
      open.forEach(function (pair) {
        var t = pair.t;
        var i = pair.i;
        var key = pair.key;
        var pending = pair.pending;
        // 正在编辑这一条 → 卡片里就地换成标题 / 时间输入。
        // 放在「完成 / 删除动画」之前：编辑中的卡片不显示圆圈，也不播完成动画。
        if (DP.editingTodoKey === key) {
          out.push(buildTodoEditCard(day, t, key, i));
          return;
        }
        // 保存后、原生回包前，晚到的旧快照可能还带着旧标题 / 旧时间 ——
        // 展示层用 pendingEdit 盖住它，等 `todoUpdate` 结果回来再放开。
        var displayTitle = t.title || '';
        var displayDue = t.due || '';
        if (DP.pendingEdit && DP.pendingEdit.day === day &&
            todoMatches(t, DP.pendingEdit.key, DP.pendingEdit.identifier)) {
          displayTitle = DP.pendingEdit.title;
          displayDue = DP.pendingEdit.time;
        }
        var check = h('span', { class: 'dpcheck' });
        // ⚠️ **只有圆圈能完成**（2026-11 用户确认）：
        // 标题 / 时间 / 卡片空白处点击都**不做事**，待办就留在那里。
        if (!pending) {
          check.addEventListener('click', (function (dd, tt, ii, kk) {
            return function (e) {
              e.stopPropagation();
              startTodoComplete(dd, tt, ii, kk);
            };
          })(day, t, i, key));
        }
        var body = h('div', { class: 'dpcardbody' },
          // ⚠️ **勾选圈 + 标题必须同属一行**（`.dpmain`）——
          //
          // 窄态列宽只有约 119pt，一行塞不下「圈 + 标题 + 到期时间」，
          // 到期时间会被挤到下一行，而**勾选圈也会跟着掉下来**
          // （表现是圈孤零零占一行，标题在下面一行 —— 很怪）。
          //
          // 所以结构上分成两层：
          //   `.dpmain` = 圈 + 标题（同一行，标题拿到全部剩余宽度）
          //   `.dptime` = 到期时间（窄态换行显示；宽态跟在标题后面）
          h('span', { class: 'dpmain' },
            check,
            h('span', { class: 'dptitle', text: displayTitle })),
          displayDue ? h('span', { class: 'dptime', text: displayDue }) : null);
        var extra = '';
        if (pending) {
          if (pending.deleting) {
            // 右键菜单「删除」：只淡出，不变成完成态的蓝圈。
            extra = 'leaving';
          } else {
            extra = 'completing' + (pending.phase === 'leaving' ? ' leaving' : '');
          }
        }
        var opts = {
          title: '点圆圈标记完成 · 右键修改 / 删除',
          todoKey: key,
          nodeKey: 'todo:' + key,
          todoIdentifier: t.identifier || '',
          todoCalendar: t.calendarIdentifier || '',
          className: extra
        };
        if (i !== null && i !== undefined) opts.todoIndex = i;
        var card = dpCard('todo',
          dpCardHead('📋', '待办事项'),
          body,
          opts);
        // ⚠️ **重绘时从已经淡到的地方接着淡**（2026-11 修）。
        //
        // `.leaving` 的 CSS 动画对**新元素**是从头播的（opacity 1 → 0）。
        // 原生在淡出那 400ms 里推一次状态 → 面板重绘 → 正在淡的条目
        // 瞬间跳回完全不透明，再淡一次（用户看到「消失一下又回来」）。
        //
        // 用**负的 animation-delay** 让新卡片直接从「已经过了多久」处开始播：
        // 视觉上无缝接着淡，不会跳回。
        if (pending && pending.phase === 'leaving') {
          var leaveElapsed = Math.max(0, nowMs() - (pending.leaveAt || 0));
          card.style.animationDelay =
            '-' + Math.min(leaveElapsed, DP_LEAVE_MS) + 'ms';
        }
        out.push(card);
      });
    }

    // 「＋ 添加待办」永远都在 —— 做成一张**虚线幽灵卡**，
    // 展开输入框时就地变高，不新开一层。
    if (DP.adding) {
      // ⚠️ **输入框复用同一个元素**（见 DP.input 的说明）：
      // 原生每推一次状态都会重绘整个面板内容，输入框要是每次新建，
      // 用户的字和焦点就全没了。
      var input = ensureInput();
      // 值以 DP.inputValue 为准（重绘时元素虽然没被换掉，
      // 但保险起见每次都对一次，免得中途被别处改过）。
      if (input.value !== DP.inputValue) input.value = DP.inputValue;
      input.setAttribute('data-day', String(day));
      // 时间：时 / 分两个小框，**和标题输入框平级**（不在蓝框里面）。
      //
      // ⚠️ 窄列里不写「时间」二字 —— 卡片内容宽只有约 86.6pt，
      // 加两个字就放不下「时分 + 添加」了。
      var hourInput = ensureTimePart('add', 'hour');
      var minuteInput = ensureTimePart('add', 'minute');
      if (hourInput.value !== (DP.timeHourValue || '00')) hourInput.value = DP.timeHourValue || '00';
      if (minuteInput.value !== (DP.timeMinuteValue || '00')) minuteInput.value = DP.timeMinuteValue || '00';
      // 标题框（蓝边）在上，时间小框 + 「取消」在下 —— 两块**平级**。
      //
      // ⚠️ 右下角这个按钮是「**取消**」，不是「添加」（2026-11 改）。
      //
      // 用户填好内容、看着这个按钮时，它该说的是「放弃这次输入」；
      // 而且添加态以前**根本没有取消按钮** —— 填错了想反悔只能按 Esc
      // （很多人不知道）。现在：
      //   · 「取消」= 关掉表单，**清空**已填的标题 / 时间（和 Esc 一致）；
      //   · 提交 = **回车**（标题框、时间框里回车都能提交）。
      //
      // 编辑态那边是「保存 / 取消」，这里也是「取消」，两个表单语义统一了。
      //
      // ⚠️⚠️ **表单 DOM 建一次就留着**（2026-11-09 修）。
      //
      // 以前每次重绘都 `h('div', ..., input)` 重新拼一个表单 ——
      // `h()` 会把 `input`（**共享的那个元素**）从旧表单里**摘走**挂到新表单上
      // → 旧表单里就没有输入框了，而且这次「搬家」会让它**失焦** →
      // `onblur` → `post('textInputBlur')` → 原生退出文本输入模式 →
      // **键盘断掉**（用户原话：「输入框出现了但是键盘无法聚焦」）。
      //
      // 原生一退出输入模式就要重新抢 key（重试 4 秒，期间窗口被反复摆到前面）
      // → **用户的点击被吃掉**（「取消要点两次」）。
      //
      // 现在：表单只建一次；重绘时**只更新值**，元素一个都不动。
      out.push(updateAddCard(ensureAddForm(input, hourInput, minuteInput)));
      // 输入框就地展开后自动聚焦。
      //
      // ⚠️ `focus()` 只在窗口是 **key window** 时才有效 ——
      // 桌面层窗口默认拿不到 key，所以网页侧调了也没用；
      // 真正让它生效的是 `onfocus` 里发给原生的 `textInputFocus`
      // （原生把窗口临时变成 key），原生那边一处理完，
      // 这里再补一次 focus() 就成了。
      setTimeout(function () { try { input.focus(); } catch (e) {} }, 60);
    } else {
      out.push(updateAddCard(null));
    }

    // ⚠️ **失败提示**（2026-11 加）——
    //
    // 以前「添加待办」失败是**完全静默**的：点了没反应，
    // 用户根本不知道是缺权限还是别的原因。
    if (DP.addError) {
      out.push(h('div', { class: 'dpadderr', text: DP.addError,
                          'data-node-key': 'todo-error' }));
    }

    return out;
  }

  // 编辑态卡片：标题输入 + 时 / 分输入 + 保存 / 取消。
  //
  // 结构（窄列里三行，宽 86.6pt 放得下）：
  //   [ 标题                     ]
  //   [ 20 ] : [ 00 ]
  //   [              保存   取消 ]
  function buildTodoEditCard(day, t, key, index) {
    var titleInput = ensureEditTitleInput();
    var hourInput = ensureTimePart('edit', 'hour');
    var minuteInput = ensureTimePart('edit', 'minute');
    if (titleInput.value !== DP.editTitleValue) titleInput.value = DP.editTitleValue;
    if (hourInput.value !== DP.editHourValue) hourInput.value = DP.editHourValue;
    if (minuteInput.value !== DP.editMinuteValue) minuteInput.value = DP.editMinuteValue;

    var body = h('div', { class: 'dpcardbody dpedit' },
      h('div', { class: 'dpeditrow' }, titleInput),
      h('div', { class: 'dpeditrow dpedittimerow' },
        hourInput,
        h('span', { class: 'dpcolon', text: ':' }),
        minuteInput),
      DP.editError ? h('div', { class: 'dpadderr', text: DP.editError }) : null,
      h('div', { class: 'dpeditbtns' },
        h('button', {
          type: 'button', class: 'dpeditbtn primary', text: '保存',
          onclick: function (e) { e.stopPropagation(); commitTodoEdit(); }
        }),
        h('button', {
          type: 'button', class: 'dpeditbtn', text: '取消',
          onclick: function (e) { e.stopPropagation(); cancelTodoEdit(); }
        })));

    var opts = {
      title: '回车保存 · Esc 取消',
      todoKey: key,
      nodeKey: 'edit:' + key,
      todoIdentifier: t.identifier || '',
      todoCalendar: t.calendarIdentifier || '',
      className: 'editing'
    };
    if (typeof index === 'number') opts.todoIndex = index;
    return dpCard('todo', dpCardHead('📋', '修改待办'), body, opts);
  }

  // 「添加待办」那张**稳定的**卡（2026-11-09 加）。
  //
  // ⚠️ 为什么必须稳定：这张卡里装着**共用的 input 元素**。
  // 每次重绘都新建一张卡 → input 被「摘下来再挂回去」→ **失焦** →
  // `onblur` → `post('textInputBlur')` → 原生退出文本输入模式 →
  // **键盘断掉**（用户原话：「输入框出现了但是键盘无法聚焦」）。
  //
  // 稳定之后：卡和 input 都不动，重绘只更新卡里的值（值本来就是同一个元素，没丢）。
  //
  // 这张卡同时装**两种形态**，用 `display` 切换：
  //   · 收起态：`.dpadd`（「＋ 添加待办」）
  //   · 展开态：`.dpaddform`（标题框 + 时分 + 取消）
  // 两种形态都**建一次就留着**，来回切换只改 display —— 元素一动都不动。
  var DP_addCard = null;        // 那张稳定的卡（.dpcard.ghost）
  var DP_addCollapsed = null;   // 收起态：.dpadd
  var DP_addExpanded = null;    // 展开态：.dpaddform

  /// 「添加待办」的表单 DOM（**建一次就留着**，重绘时只更新值）。
  var DP_addForm = null;

  /// 焦点是不是**还在同一个表单里**（没离开）。
  ///
  /// ⚠️ 为什么需要它（2026-11-09 修「时间输入不了 / 输入不连贯」）：
  ///
  /// 标题框 → 时框 → 分框 之间来回切，**每个框都会先 blur 再 focus**。
  /// 以前每个框的 `onblur` 都**无条件** `post('textInputBlur')` →
  /// 原生 `setTextInputMode(false)` → **键盘断掉**（焦点刚落到下一个框，
  /// 键盘已经被收走了）→ 后面那个框根本打不了字。
  ///
  /// 现在：只有**真的离开整个表单**了才告诉原生退出文本输入模式。
  ///
  /// - Parameter root: 表单的根节点（`.dpaddform` / `.dpedit`）。
  /// - Parameter from: 刚失焦的那个元素。
  function focusStillInside(root, from) {
    if (typeof window !== 'undefined' && window.__ttGuardLog) {
      try {
        var a = document.activeElement;
        window.__ttGuardLog.push('guard:' + (from ? (from.getAttribute('data-dp-time-part') ||
            from.getAttribute('data-dp-input') || (from.className || from.tagName)) : '?') +
          ' active=' + (a ? (a.getAttribute('data-dp-time-part') || a.getAttribute('data-dp-input') ||
            (a.className || a.tagName)) : 'none') +
          ' root=' + (root ? (root.className || root.tagName) : 'null') +
          ' inside=' + (!!(a && a !== document.body && root && root.contains(a))));
      } catch (e) {}
    }
    // 失焦时 `document.activeElement` 可能已经是 body（焦点还没落到下一个框），
    // 这时**不能**立刻判成「离开了」—— 要等下一个 tick 看焦点落到了哪。
    var active = document.activeElement;
    if (active && active !== document.body && root && root.contains(active)) return true;
    // 焦点还在**同一个表单**里（说明只是框之间切换）？
    if (active && from && from.parentNode && from.parentNode.contains &&
        from.parentNode.contains(active)) return true;
    return false;
  }

  /// 拿到（或建）那个**稳定的**表单节点。
  ///
  /// ⚠️ 绝不能每次重绘都重新 `h(...)` —— 那样会把**共享的 input 元素**
  /// 从旧表单里摘走（搬家 → 失焦 → 键盘断掉）。
  function ensureAddForm(input, hourInput, minuteInput) {
    if (!DP_addForm) {
      DP_addForm = h('div', { class: 'dpaddform' },
        h('div', { class: 'dpinputrow' }, input),
        h('div', { class: 'dpinputrow dptimerow' },
          hourInput,
          h('span', { class: 'dpcolon', text: ':' }),
          minuteInput,
          h('span', {
            class: 'dpok', text: '取消',
            title: '放弃这次输入（回车提交）',
            onclick: (function () { return function (e) { e.stopPropagation(); closeTodoCompose(); }; })()
          })));
    }
    return DP_addForm;
  }

  /// 拿到（或建）那张稳定的「添加待办」卡，并切到对应形态。
  ///
  /// - Parameter body: 展开态的表单节点（`null` = 收起态）。
  function updateAddCard(body) {
    if (typeof window !== 'undefined' && window.__ttCardLog) {
      try { window.__ttCardLog.push('updateAddCard body=' + (body ? 'form' : 'null') +
        ' adding=' + DP.adding + '@' + Math.round(performance.now()) + ':' +
        (new Error()).stack.split('\n').slice(1,3).join(' <- ')); } catch (e) {}
    }
    if (!DP_addCard) {
      // 收起态：点击它 = 打开输入框。
      DP_addCollapsed = h('div', { class: 'dpadd' },
        h('span', { class: 'plus', text: '＋' }),
        h('span', { text: '添加待办' }));
      DP_addCard = dpCard('ghost', null, DP_addCollapsed, {
        title: '添加待办',
        nodeKey: 'add',
        onclick: (function () {
          return function (e) {
            e.stopPropagation();
            // ⚠️⚠️ **只有点在「＋ 添加待办」那个标签上才打开输入框**（2026-11-09 修）。
            //
            // 这张卡现在是**稳定节点**，里面装着**展开态的表单**（标题框 + 时分 + 取消）。
            // 以前每次重绘都重建这张卡，展开态的表单和收起态是**两个不同的节点**，
            // 点表单不会被这张卡接住。
            //
            // 改成稳定节点之后，**点表单里的时 / 分框也会冒泡到这张卡** →
            // 触发「重新打开输入框」→ `renderPanel()` → **面板整个重建**
            //   · 面板里的待办卡片被换掉 → 用户看到「上面的待办事项没了」；
            //   · 时 / 分框被摘下来再挂回去 → **失焦** → 键盘断掉
            //     → 用户看到「时间输入不了 / 输入不连贯」。
            //
            // 实测事件序列（点时框）：
            //   focus:add-hour → blur:add-hour（6ms 后）→ 焦点跑了 → 键盘断
            //
            // 修法：只有点在收起态的标签（`.dpadd`）上才当作「打开输入框」。
            // 表单里的点击一律不管（输入框自己的 handler 处理）。
            if (e.target && e.target.closest && e.target.closest('.dpaddform')) return;
            if (DP.adding) return;
            // ⚠️ **点「添加待办」就立刻把权限处理掉**（2026-11 修）。
            //
            // 以前只有回车提交（`todoAdd`）时才请求提醒事项 / 日历权限：
            // 用户打完字按回车，系统权限框才弹出来，待办要等授权完
            // 才出现 —— 第一次用时看起来像「回车没反应」。
            //
            // 「点添加待办」已经是明确的意图，这时候就发 `todoCompose`，
            // 原生立即弹权限框；等用户打完字，权限早就处理完，回车直接写入。
            post('todoCompose', { day: currentAddDay() });
            DP.adding = true;
            // 重新打开输入框时**清掉上次的残留内容** ——
            // 输入框是复用的同一个元素，不清的话会带着上次没提交的字。
            DP.inputValue = '';
            DP.timeHourValue = '';
            DP.timeMinuteValue = '';
            if (DP.input) DP.input.value = '';
            if (DP.timeHour) DP.timeHour.value = '';
            if (DP.timeMinute) DP.timeMinute.value = '';
            // 打开输入框 = 用户要重来一次 → 旧的失败提示先清掉。
            DP.addError = '';
            renderPanel();
          };
        })()
      });
    }
    if (body) {
      // 展开态：表单节点是**稳定的那个**（`ensureAddForm`），
      // 只需要把它挂进卡里 + 切显示，**不碰里面的任何元素**。
      if (DP_addExpanded !== body) {
        DP_addExpanded = body;
        DP_addCard.appendChild(DP_addExpanded);
      }
      if (DP_addCollapsed) DP_addCollapsed.style.display = 'none';
      DP_addExpanded.style.display = '';
    } else {
      // 收起态：只切显示，**不碰表单里的任何元素**。
      if (DP_addCollapsed) DP_addCollapsed.style.display = '';
      if (DP_addExpanded) DP_addExpanded.style.display = 'none';
    }
    return DP_addCard;
  }

  /// 「＋ 添加待办」那一列是哪天（点它的时候要知道往哪列加）。
  function currentAddDay() {
    return DP.day || 1;
  }

  // 拿到（必要时创建）那个**共用的**输入框元素。
  //
  // ⚠️ 关键点：**只创建一次**，之后每次重绘都复用同一个元素 ——
  // 这样重绘（原生推状态、换列…）既不会丢字，也不会丢焦点。
  function ensureInput() {
    if (DP.input && DP.input.parentNode) return DP.input;
    if (DP.input) return DP.input;   // 元素还在（只是被摘下来了）
    var input = h('input', {
      type: 'text',
      class: 'dptitlefield',
      placeholder: '添加待办…',
      maxlength: '80',
      'data-dp-input': '1',
      value: DP.inputValue || '',
      // ⚠️ **必须报告焦点状态给原生** ——
      //
      // 桌面层窗口是 `.nonactivatingPanel`（永远不能成为 key window），
      // 所以 WKWebView 拿不到键盘焦点 —— 输入框能显示、能点开，
      // 但**打不进字**。
      //
      // 这里在聚焦时告诉原生「用户要打字了」，原生把窗口临时变成 key，
      // 按键就能进网页了；失焦（或者回车 / Esc）再还原。
      // ⚠️ 点标题框也要**阻止冒泡**（2026-11-09 修）——
      // 否则会冒到「添加待办」那张卡 → 面板重建 → 焦点丢失。
      onclick: function (e) {
        if (e && e.stopPropagation) e.stopPropagation();
        try { input.focus(); } catch (err) {}
      },
      onfocus: function () {
        DP.inputValue = input.value;
        post('textInputFocus', {});
      },
      onblur: function () {
        DP.inputValue = input.value;
        // ⚠️ **焦点还在同一个表单里 → 不要退出文本输入模式**（2026-11-09 修）。
        //
        // 标题框 → 时框 会先 blur 标题框；以前无条件 `post('textInputBlur')`
        // → 原生把键盘收走 → 时框打不了字（「时间输入还是有问题」）。
        var root = input.closest ? input.closest('.dpaddform') : null;
        setTimeout(function () {
          if (focusStillInside(root, input)) return;
          post('textInputBlur', {});
        }, 0);
      },
      oninput: function () {
        DP.inputValue = input.value;
        // 开始改标题 → 上一次的红色提示撤掉。
        if (typeof clearAddError === 'function') clearAddError();
      },
      onkeydown: function (e) {
        e.stopPropagation();
        DP.inputValue = input.value;
        // ⚠️ **当天数要从元素上读**，不能闭包捕获 ——
        // 输入框是**跨天复用**的同一个元素，捕获的那天早就过期了。
        var dd = parseInt(input.getAttribute('data-day') || '', 10);
        if (isNaN(dd)) dd = DP.day || 1;
        if (e.key === 'Enter' || e.keyCode === 13) { commitTodo(dd, input); }
        else if (e.key === 'Escape' || e.keyCode === 27) {
          closeTodoCompose();
        }
      }
    });
    DP.input = input;
    return input;
  }

  // Esc 的统一出口（原生 AppKit 的 cancelOperation 也调这里）。
  //
  // ⚠️ 为什么不能只靠输入框自己的 onkeydown（2026-11-08 修「Esc 要按两下」）：
  //   · 窗口刚被切成 key 时，第一下 Esc 可能被 AppKit 的取消链路
  //     （`cancelOperation`）先接走，根本没到 DOM；
  //   · 用中文输入法时，第一下 Esc 是「取消组词」，属于输入法自己。
  // 所以再挂一个**文档级**兜底 + 给原生一个直接调用的入口。
  window.ttCancelEditing = function () {
    if (DP.adding) { closeTodoCompose(); return true; }
    if (DP.editingTodoKey) { cancelTodoEdit(); return true; }
    // 写日记时 Esc 也要能取消（2026-11-10）。
    if (DP.diaryForm) { closeDiaryForm(); return true; }
    return false;
  };

  document.addEventListener('keydown', function (e) {
    if (e.key !== 'Escape' && e.keyCode !== 27) return;
    // 输入法正在组词 → 这一下先让输入法自己取消。
    if (e.isComposing || e.keyCode === 229) return;
    if (DP.adding || DP.editingTodoKey || DP.diaryForm) {
      e.preventDefault();
      window.ttCancelEditing();
    }
  }, false);

  // 收起「添加待办」输入区（Esc / 空标题 / 提交成功共用）。
  function closeTodoCompose() {
    DP.adding = false;
    DP.inputValue = '';
    DP.timeHourValue = '';
    DP.timeMinuteValue = '';
    // ⚠️ **取消 / 收起时必须清掉失败提示**（2026-11-09 修）
    // 以前只在「提交成功」那条路上清，于是「时间填错 → 取消添加」之后
    // 红色提示会一直挂在面板上（用户：「取消了添加待办还在」）。
    DP.addError = '';
    post('textInputBlur', {});
    renderPanel();
  }

  /// 用户一开始改输入内容，就把上一次的失败提示撤掉。
  /// 只摘 DOM 节点、不整块重绘 —— 重绘会把输入框重新挂一遍，焦点 / 输入法就断了。
  function clearAddError() {
    if (!DP.addError) return;
    DP.addError = '';
    var el = document.querySelector('.dpadderr');
    if (el && el.parentNode) el.parentNode.removeChild(el);
  }

  function commitTodo(day, input) {
    var v = input && input.value ? String(input.value).trim() : '';
    DP.inputValue = v;
    if (!v) {
      closeTodoCompose();
      return;
    }
    // 时间：两个都空 = 00:00；只填一位会自动补零；非法就地提示、不提交。
    var parts = parseTodoTimeParts(DP.timeHourValue, DP.timeMinuteValue);
    if (!parts) {
      DP.addError = '时间请用 00:00–23:59';
      renderPanel();
      applyNarrowLimit();
      setTimeout(function () { focusTimePart('add', 'hour'); }, 0);
      return;
    }
    post('todoAdd', { day: day, title: v, time: parts.text });
    DP.adding = false;
    DP.inputValue = '';
    DP.timeHourValue = '';
    DP.timeMinuteValue = '';
    // ⚠️ **清掉上一次的失败提示** ——
    // 不清的话，失败一次之后这个提示会一直挂在面板上。
    DP.addError = '';
    post('textInputBlur', {});
    renderPanel();
  }

  // 日程块：**每条日程一张卡片**。
  //
  // ⚠️ **永远渲染**（哪怕一条日程都没有）——
  // 三张卡片必须都在，缺一块的话面板每次数据到达的时机不同，
  // 高度会跳来跳去（用户看到的是「内容忽上忽下」）。
  // ---------------------------------------------------------------------------
  // 日记（2026-11-10 新增）
  //
  // 它是日期覆盖层里的**第三块**内容：待办（提醒事项）/ 日程（系统日历）/
  // 日记（app 自己的 diary.json）。数据由原生 `DayPanelController` 推来：
  //   data.diary = [{ id, title, body, time }]
  //
  // ⚠️ 表单节点**只创建一次**（`ensureDiaryForm`），之后只切 display / 改 value ——
  // 和「添加待办」同一个教训：每次重绘重建 input 会把元素摘下来再挂回去，
  // 结果就是失焦 + 键盘断。
  var DP_diaryCard = null;
  var DP_diaryBody = null;
  var DP_diaryList = null;
  var DP_diaryFormEl = null;
  var DP_diaryTitleEl = null;
  var DP_diaryTimeEl = null;
  var DP_diaryTextEl = null;
  var DP_diaryDay = null;

  function diaryTimeText(v) {
    // 只收数字：`2030` / `20:30` / `9:5` 都归成 `HH:mm`；空 = 不写时间。
    var digits = String(v || '').replace(/\D/g, '');
    if (!digits) return '';
    if (digits.length === 1) digits = '0' + digits;
    if (digits.length === 2) return digits + ':00';
    if (digits.length === 3) digits = '0' + digits;
    digits = digits.slice(0, 4);
    var h = parseInt(digits.slice(0, 2), 10);
    var m = parseInt(digits.slice(2, 4), 10);
    if (!(h >= 0 && h <= 23)) h = 0;
    if (!(m >= 0 && m <= 59)) m = 0;
    return ('0' + h).slice(-2) + ':' + ('0' + m).slice(-2);
  }

  function ensureDiaryForm() {
    if (DP_diaryFormEl) return DP_diaryFormEl;
    DP_diaryTitleEl = h('input', {
      class: 'dpdiary-title', type: 'text', placeholder: '标题（可空）',
      autocomplete: 'off', spellcheck: 'false'
    });
    DP_diaryTitleEl.addEventListener('focus', function () {
      post('textInputFocus', {});
    });
    DP_diaryTextEl = h('textarea', {
      class: 'dpdiary-text', placeholder: '写点什么…', rows: '3'
    });
    DP_diaryTextEl.addEventListener('focus', function () {
      post('textInputFocus', {});
    });

    var save = h('span', {
      class: 'dpok', text: '保存',
      onclick: function (e) { e.stopPropagation(); submitDiary(); }
    });
    var cancel = h('span', {
      class: 'dpcancel', text: '取消',
      onclick: function (e) { e.stopPropagation(); closeDiaryForm(); }
    });
    // ⚠️ 面板列很窄（约 86pt）：**不放时间输入框** ——
    // 「标题 + 时间」并排会把两个框都挤成一条缝（实测截断成「21:3(」）。
    // 时间改在设置 →「日记」的编辑框里填；这里只写标题 + 正文。
    // ⚠️ 表单里**不放「删除」**（2026-11-10 用户要求）：列只有 ~86pt，
    // 「删除」被挤到卡片外面。删除改走**右键菜单**（和待办一致）。
    DP_diaryFormEl = h('div', { class: 'dpdiaryform' },
      DP_diaryTitleEl,
      DP_diaryTextEl,
      h('div', { class: 'dpaddact' }, cancel, save));
    DP_diaryFormEl.style.display = 'none';
    return DP_diaryFormEl;
  }

  function openDiaryForm(mode, entry) {
    ensureDiaryForm();
    DP.diaryForm = mode === 'edit'
      ? { mode: 'edit', id: entry.id }
      : { mode: 'add' };
    DP_diaryTitleEl.value = entry ? (entry.title || '') : '';
    DP_diaryTextEl.value = entry ? (entry.body || '') : '';
    // 时间在面板里不可编辑，但**编辑时不能把原来的时间弄丢** ——
    // 记住它，提交时原样带回去（真正改时间走设置里的编辑框）。
    DP.diaryForm.time = entry ? (entry.time || '') : '';
    DP_diaryFormEl.style.display = '';
    renderPanel();
    // 面板重绘之后表单元素还是同一批（稳定节点），直接聚焦。
    setTimeout(function () {
      try { DP_diaryTitleEl.focus(); } catch (e) {}
    }, 0);
  }

  function closeDiaryForm() {
    DP.diaryForm = null;
    if (DP_diaryFormEl) DP_diaryFormEl.style.display = 'none';
    renderPanel();
  }

  function submitDiary() {
    if (!DP.diaryForm) return;
    var title = (DP_diaryTitleEl.value || '').trim();
    var body = (DP_diaryTextEl.value || '').trim();
    if (!title && !body) { closeDiaryForm(); return; }
    var payload = {
      day: DP.day,
      title: title,
      body: body,
      time: DP.diaryForm.time || ''
    };
    if (DP.diaryForm.mode === 'edit') {
      payload.id = DP.diaryForm.id;
      post('diaryUpdate', payload);
      // 改：本地也先覆盖掉旧内容（原生推回来之后用真实数据替换）。
      DP.diaryPending = (DP.diaryPending || []).filter(function (p) {
        return !(p.id === payload.id);
      });
      DP.diaryPending.push({ id: payload.id, title: title, body: body,
                             time: payload.time, localEdit: true });
    } else {
      post('diaryAdd', payload);
      // ⚠️ **乐观插入**（2026-11-10 修「点了保存但是没显示出来」）。
      // 原生写盘 / 推状态是异步的，中间还可能有「换天清空」的中间态；
      // 这段时间里用户看不到自己刚写的东西，就会以为没保存成功。
      // 先在本地挂一条，原生推回来之后按「标题 + 正文 + 时间」自动去掉。
      DP.diaryPending = DP.diaryPending || [];
      DP.diaryPending.push({ id: 'local-' + Date.now(), title: title, body: body,
                             time: payload.time });
    }
    closeDiaryForm();
  }

  /// 日记卡片（**稳定节点**：列表每次重建，表单永远不重建）。
  function dpDiarySection(data, day) {
    var items = (data && data.diary) || [];
    if (DP_diaryDay !== day) {
      // 换天了：把表单收起来（不然会把昨天的草稿写进今天）。
      DP_diaryDay = day;
      DP.diaryForm = null;
      DP.diaryPending = [];
    }
    // 原生已经推回来、内容对得上的「本地乐观条」→ 去掉（避免出现两条一样的）。
    var pending = DP.diaryPending || [];
    pending = pending.filter(function (p) {
      // 原生推回来的「真」条目和本地 optimistic 条内容一致 → 本地那条可以撤了。
      return !items.some(function (d) {
        return (d.title || '') === (p.title || '') &&
               (d.body || '') === (p.body || '') &&
               (d.time || '') === (p.time || '');
      });
    });
    // 编辑态：原生的那条如果已经是改后的内容，就把本地那条也去掉。
    pending = pending.filter(function (p) {
      if (!p.localEdit) return true;
      var hit = items.some(function (d) {
        return d.id === p.id && (d.title || '') === (p.title || '') &&
               (d.body || '') === (p.body || '');
      });
      return !hit;
    });
    DP.diaryPending = pending;
    // 之前因为「还没拿到真实 id」排队的删除，现在数据到了 → 补发。
    if ((DP.diaryPendingDeletes || []).length) {
      var stillQueued = [];
      DP.diaryPendingDeletes.forEach(function (localID) {
        var real = resolveDiaryID(localID);
        if (real) post('diaryDelete', { id: real, day: DP.day });
        else stillQueued.push(localID);
      });
      DP.diaryPendingDeletes = stillQueued;
    }
    if (pending.length) {
      items = items.filter(function (d) {
        return !pending.some(function (p) { return p.localEdit && p.id === d.id; });
      }).concat(pending.map(function (p) {
        return { id: p.id, title: p.title, body: p.body, time: p.time };
      }));
    }
    ensureDiaryForm();
    if (!DP_diaryCard) {
      DP_diaryList = h('div', { class: 'dpdiarylist' });
      DP_diaryBody = h('div', { class: 'dpdiarybody' },
        DP_diaryList,
        h('div', {
          class: 'dpadd dpdiaryadd',
          onclick: function (e) {
            e.stopPropagation();
            if (DP.diaryForm) return;
            openDiaryForm('add', null);
          }
        },
          h('span', { class: 'plus', text: '＋' }),
          h('span', { text: '写日记' })),
        ensureDiaryForm());
      DP_diaryCard = dpCard('diary', dpCardHead('📔', '日记'), DP_diaryBody, {
        title: '日记',
        nodeKey: 'diary'
      });
    }
    // ---- 列表（每次重绘都重建，但**不碰表单**）----
    DP_diaryList.textContent = '';
    if (!items.length) {
      DP_diaryList.appendChild(h('div', { class: 'dpempty', text: '今日没有日记' }));
    } else {
      items.forEach(function (d) {
        var row = h('div', {
          class: 'dpdiaryrow',
          'data-diary-id': d.id,
          title: '点一下修改 · 右键可删除',
          onclick: function (e) {
            e.stopPropagation();
            if (DP.diaryForm) return;
            openDiaryForm('edit', d);
          }
        },
          h('div', { class: 'dpdiaryhead' },
            h('span', { class: 'dpdiaryt', text: d.time || '' }),
            h('span', { class: 'dpdiaryname', text: d.title || '（未命名）' })),
          d.body ? h('div', { class: 'dpdiarytxt', text: d.body }) : null);
        DP_diaryList.appendChild(row);
      });
    }
    // 表单显示状态跟着 DP.diaryForm 走（重绘后要重新应用）。
    var open = !!DP.diaryForm;
    DP_diaryFormEl.style.display = open ? '' : 'none';
    var addRow = DP_diaryBody.querySelector('.dpdiaryadd');
    if (addRow) addRow.style.display = open ? 'none' : '';
    return [DP_diaryCard];
  }

  function dpEventSection(data) {
    var events = (data && data.events) || [];
    var out = [];
    if (!events.length) {
      // 同待办块：没查完就显示「读取中…」，不要先说「今日无日程」再闪成真实内容。
      var eventLoading = panelLoading(data);
      out.push(dpCard('empty',
        dpCardHead('📅', '日历行程'),
        h('div', { class: 'dpempty' + (eventLoading ? ' dploading' : ''),
                   text: eventLoading ? '读取中…' : '今日无日程' }),
        { nodeKey: 'event-empty' }));
    } else {
      events.forEach(function (ev, evi) {
        var body = h('div', { class: 'dpcardbody' },
          h('span', { class: 'dpevt', text: ev.title || '' }));
        // 起止时间（`14:00–15:30`）—— 有起**和**止才显示区间，
        // 只有开始时间就只显示开始时间（不要显示成「14:00–」）。
        var span = '';
        if (ev.start && ev.end) span = ev.start + '–' + ev.end;
        else if (ev.start) span = ev.start;
        else if (ev.end) span = ev.end;
        if (span) {
          body.appendChild(h('div', { class: 'dpevs', text: span }));
        }
        out.push(dpCard('event', dpCardHead('📅', '日历行程'), body, {
          // 有系统 id 就用 id；老数据 / 注入的没有 id → 用标题 + 时刻 + 序号，
          // 保证同一份数据每次算出来的键一样。
          nodeKey: 'event:' + (ev.identifier ||
            ('i' + evi + '|' + String(ev.title || '') + '|' + String(ev.start || '') +
             '|' + String(ev.end || '')))
        }));
      });
    }
    return out;
  }

  // 「今日详情」：**一张卡片**（农历 / 节气 / 节日 / 天气 / 宜忌）。
  //
  // ⚠️ **永远渲染** —— 用户明确要求「七列的今日详情都要有」。
  // 以前这里在 lunar / term / festivals 全空时 `return null`，
  // 整块消失 → 「有的列有今日详情、有的列没有」。
  //
  // 现在：
  //   · 有农历 → 一定显示农历（哪怕今天不是任何节日）；
  //   · 连农历都拿不到（原生还没推 / 推错了天）→ 显示占位提示。
  //
  // ⚠️ **天气 / 宜忌拿不到就整行不显示** ——
  // 绝不能显示假数据（比如「0°」或编出来的宜忌）。
  function dpFestivalSection(data) {
    var f = data && data.festival;
    var lunar = '';
    var term = '';
    var names = [];
    var weather = null;
    var yi = '';
    var ji = '';
    if (f && typeof f === 'object') {
      lunar = f.lunar ? String(f.lunar) : '';
      term = f.term ? String(f.term) : '';
      var list = f.festivals || [];
      for (var i = 0; i < list.length; i++) {
        if (list[i]) names.push(String(list[i]));
      }
      // 天气是**可选字段** —— 原生没给 / 没城市 / 请求失败时整个字段是 null。
      if (f.weather && typeof f.weather === 'object') {
        var w = f.weather;
        var desc = w.text ? String(w.text) : '';
        var temp = w.temperature !== undefined && w.temperature !== null
          ? String(w.temperature) : '';
        // 温度显示成「12° / 21°」（最低 / 最高）。
        var lo = w.min !== undefined && w.min !== null ? String(w.min) : '';
        var hi = w.max !== undefined && w.max !== null ? String(w.max) : '';
        var tline = '';
        if (lo && hi) tline = lo + '° / ' + hi + '°';
        else if (temp) tline = temp + '°';
        // 描述和温度都没有 → 天气行**不显示**（不要出现一个空的天气行）。
        if (desc || tline) {
          weather = { desc: desc, temp: tline };
        }
      }
      if (f.yi) yi = String(f.yi);
      if (f.ji) ji = String(f.ji);
    }

    var body = h('div', { class: 'dpcardbody dpfest' });
    if (lunar) {
      body.appendChild(h('span', { class: 'dplunar', text: lunar }));
    } else {
      // 连农历都拿不到 → 占位（而不是把整块藏起来）。
      body.appendChild(h('span', { class: 'dpempty', text: '暂无节日信息' }));
    }
    if (term) body.appendChild(h('span', { class: 'fchip', text: term }));
    for (var j = 0; j < names.length; j++) {
      body.appendChild(h('span', { class: 'fchip', text: names[j] }));
    }
    // 天气行（有才显示）。
    if (weather) {
      body.appendChild(h('div', { class: 'dpweather' },
        h('span', { class: 'dpwicon', text: weather.desc ? weatherGlyph(weather.desc) : '·' }),
        h('span', { class: 'dpwdesc', text: weather.desc }),
        weather.temp ? h('span', { class: 'dpwtemp', text: weather.temp }) : null));
    }
    // 宜 / 忌（离线算出来的；拿不到就不显示）。
    if (yi || ji) {
      body.appendChild(h('div', { class: 'dpyiji' },
        yi ? h('span', { class: 'dpyi', text: '宜：' + yi }) : null,
        ji ? h('span', { class: 'dpji', text: '忌：' + ji }) : null));
    }

    return [dpCard('detail', dpCardHead('🎊', '今日详情'), body,
                   { nodeKey: 'detail' })];
  }

  // 天气现象 → 一个简单的小图形（不引图片资源，避免打包体积）。
  //
  // 只按「现象关键词」猜，猜不到就用中性的 ·。
  function weatherGlyph(desc) {
    var s = String(desc || '');
    if (s.indexOf('雪') >= 0) return '❄';
    if (s.indexOf('雨') >= 0) return '☂';
    if (s.indexOf('雾') >= 0 || s.indexOf('霾') >= 0) return '☁';
    if (s.indexOf('阴') >= 0) return '☁';
    if (s.indexOf('云') >= 0) return '⛅';
    if (s.indexOf('晴') >= 0) return '☀';
    return '·';
  }

  // ---- 覆盖层构建 / 更新 ----

  // 把新卡片列表**按稳定键合并**进 `.dpcards`。
  //
  // 为什么不再「清空 → 全部重建」（2026-11 再修）：
  //   · 整块重建 = 半透明玻璃面板整体重绘一次，用户看到的就是「闪一下」；
  //   · 更要命的是**正在点的卡片会被换掉**：mousedown 落在旧节点、
  //     mouseup 落在新节点 → 这次 click 直接丢失。用户反馈「点两条
  //     完成，只消失了一条」就是这个（原生日志里只收到一次 toggle）。
  //
  // 规则：
  //   · 键相同、长相也相同（建节点那一刻的 outerHTML 一致）→ **复用旧节点**；
  //   · 只有新增 / 删除 / 真正改动的那张卡片会被换掉；
  //   · 最后按新列表的顺序重排。
  //
  // 指纹用**创建时**的 outerHTML（存在节点属性上）：之后对节点的临时修改
  // （比如点圆圈时直接加 `.completing`）不会污染指纹。
  function syncCards(container, nodes) {
    var oldByKey = {};
    var i, child;
    for (i = 0; i < container.children.length; i++) {
      child = container.children[i];
      var k = child.getAttribute('data-node-key');
      if (k) oldByKey[k] = child;
    }
    var used = {};
    var prev = null;
    for (i = 0; i < nodes.length; i++) {
      var node = nodes[i];
      var key = node.getAttribute('data-node-key') || '';
      if (node.__dpSig === undefined) node.__dpSig = node.outerHTML;
      var keep = node;
      // ⚠️ 「添加待办」那张卡**已经是稳定节点**了（`updateAddCard` 建一次就留着），
      // 所以它可以正常复用 —— 复用它的意义就是**别把 input 元素搬走**
      // （搬走 → 失焦 → 原生退出文本输入模式 → 键盘断掉，2026-11-09 修）。
      //
      // 编辑态那张卡（`edit:*`）**仍然不能复用**：它里面的标题框是
      // 「就地编辑」用的独立元素，建新节点时会被搬进新卡。
      if (key && key.indexOf('edit:') !== 0 &&
          oldByKey[key] && !used[key] &&
          oldByKey[key].__dpSig === node.__dpSig) {
        keep = oldByKey[key];
        used[key] = true;
      }
      var ref = prev ? prev.nextSibling : container.firstChild;
      if (keep !== ref) container.insertBefore(keep, ref);
      prev = keep;
    }
    // 排好之后，`prev` 后面剩下的都是被删掉的旧卡片。
    var tail = prev ? prev.nextSibling : container.firstChild;
    while (tail) {
      var next = tail.nextSibling;
      container.removeChild(tail);
      tail = next;
    }
  }

  // 只重建内容，不动位置（换列 / 改宽时用）
  function renderPanel() {
    if (DP.day === null) return;
    if (!DP.body) { buildPanel(); if (!DP.body) return; }

    var data = panelDataFor(DP.day);
    var body = DP.body;

    // ⚠️ **内容没变就不重建 DOM**（2026-11 修「闪几下」）。
    //
    // 原生一次操作会推好几版状态：内容一版、红点一版、重试又一版。
    // 其中内容相同的那些版本也走这里 → 每次清空 `.dpbody` 重建。
    // 面板是半透明玻璃，重绘一次就能看出「闪一下」；表头 / 日历块
    // 跟着一起重画，用户看到的就是「头部闪、日历也闪」。
    //
    // 指纹覆盖**所有会改变面板长相的输入**：数据、完成中的条目及其阶段、
    // 输入框展开状态、失败提示。注意**不含输入框里的文字** ——
    // 打字时不该重建（那样会丢字/丢焦点）。
    var pendingSig = '';
    if (DP.pendingDone) {
      var pkeys = Object.keys(DP.pendingDone).sort();
      for (var pi = 0; pi < pkeys.length; pi++) {
        var pe = DP.pendingDone[pkeys[pi]];
        pendingSig += pkeys[pi] + ':' + (pe && pe.phase) + ':' +
          (pe && pe.day) + ':' + (pe && pe.index) + '|';
      }
    }
    var pendingEditSig = '';
    if (DP.pendingEdit) {
      pendingEditSig = [DP.pendingEdit.key, DP.pendingEdit.identifier,
                        DP.pendingEdit.title, DP.pendingEdit.time].join('|');
    }
    // ⚠️ **日记表单的开 / 关 / 换条目也必须进指纹**（2026-11-10 修）：
    // 以前指纹里没有它 → 点「＋ 写日记」时「内容没变」直接早退，
    // 于是 `dpDiarySection` 根本没跑，「＋ 写日记」那一行还挂在那儿
    //（用户：「点了写日记之后怎么还有一个加号写日记」）。
    var diaryFormSig = DP.diaryForm
      ? (DP.diaryForm.mode + ':' + (DP.diaryForm.id || ''))
      : 'none';
    var diaryPendingSig = (DP.diaryPending || []).length;
    var renderKey = JSON.stringify([
      DP.day, data, pendingSig, DP.adding, DP.addError,
      DP.editingTodoKey, DP.editError, pendingEditSig,
      diaryFormSig, diaryPendingSig
    ]);
    if (renderKey === DP.renderKey && body.firstChild) {
      // 内容一样 → 位置 / 滚动 / 焦点都不用动。
      return;
    }
    DP.renderKey = renderKey;

    // ⚠️ **宽态的滚动位置要保住** ——
    // 内容重建会把 .dpbody 的子节点全换掉，滚动位置随之归零。
    // 宽态内容超高时用户正在往下看，原生这时推来一次状态（哪怕数据没变），
    // 视图就弹回顶部 —— 看着像「面板自己跳了一下」。
    var keepScroll = body.scrollTop;

    // ⚠️ **记住输入框有没有焦点**（2026-11 修）。
    //
    // 内容重建会把输入框**从 DOM 里摘下来再挂回去** ——
    // 元素虽然还是同一个（值和字都保住了），
    // 但「摘下来」这一步会**让它失焦**，挂回去之后焦点就丢了。
    //
    // 表现就是用户说的「**移动鼠标了之后，添加待办那里的输入的竖线一直在闪**」：
    // 鼠标一动 → 原生推一次状态 → 面板重绘 → 输入框失焦又 refocus
    // → **光标（那个竖线）反复闪烁**。
    //
    // 重建完把它 focus 回去就好了（值本来就是同一个元素，没丢）。
    // 焦点可能是「添加」的标题 / 时 / 分，也可能是编辑态的标题 / 时 / 分 ——
    // 它们都只建一次、跨重绘复用，所以记住是**哪一个**再还回去。
    var activeInput = document.activeElement;
    var inputFocusTarget = null;
    if (activeInput === DP.input ||
        activeInput === DP.timeHour || activeInput === DP.timeMinute ||
        activeInput === DP.editTitle ||
        activeInput === DP.editHour || activeInput === DP.editMinute) {
      inputFocusTarget = activeInput;
    }
    var inputHadFocus = !!(inputFocusTarget && inputFocusTarget.parentNode);

    // ⚠️ **就地合并卡片，不要清空重造**（2026-11 再修「消失时还闪」）。
    //
    // 上一版只靠渲染指纹挡住了「数据没变」的重绘；可只要**真变了**
    // （比如完成一条待办让数据里少了一条），这里依旧把整个 `.dpcards`
    // 清空重造 → 玻璃面板整体重绘一次，看起来还是闪；而且正在点的卡片
    // 如果在 mousedown / mouseup 之间被换掉，那一下点击会**整个丢失**
    //（用户反馈「点两条完成只消失了一条」）。
    //
    // 现在按稳定键合并：没变的卡片原样留着，只换掉真正变化的那一张。
    //
    // ⚠️ **不再截断**（2026-11 改）：
    //
    // 以前窄态按「最多能放下多少条」裁一刀，装不下的用「还有 N 条」收尾。
    // 用户明确要求改成**面板内滚动** —— 条目一条都不能少，
    // 装不下就在面板里滚。
    var cards = body.querySelector('.dpcards');
    if (!cards) {
      cards = h('div', { class: 'dpcards' });
      body.appendChild(cards);
    }
    var newCards = [];
    var todoCards = dpTodoSection(data, DP.day);
    var diaryCards = dpDiarySection(data, DP.day);
    var eventCards = dpEventSection(data);
    var detailCards = dpFestivalSection(data);
    for (var ci = 0; ci < todoCards.length; ci++) newCards.push(todoCards[ci]);
    for (var cd = 0; cd < diaryCards.length; cd++) newCards.push(diaryCards[cd]);
    for (var cj = 0; cj < eventCards.length; cj++) newCards.push(eventCards[cj]);
    for (var ck = 0; ck < detailCards.length; ck++) newCards.push(detailCards[ck]);
    syncCards(cards, newCards);

    // 滚动位置还原
    //
    // ⚠️ **窄态也要保** —— 现在窄态也能滚了（以前窄态根本不滚），
    // 原生每推一次状态都重绘内容，滚动位置会归零。
    // 用户正往下看时被弹回顶部，看着像「面板自己跳了一下」。
    if (keepScroll) body.scrollTop = keepScroll;

    // ⚠️ **把焦点还给输入框**（2026-11 修）——
    //
    // 见上面 `inputHadFocus` 的说明：重建会让它失焦，
    // 焦点一丢，那个竖线（光标）就会反复闪烁。
    //
    // 用 `setTimeout(0)` 而不是立刻 focus ——
    // 刚挂回 DOM 的元素当帧里 focus 有时会被浏览器忽略。
    // 焦点恢复：**编辑态优先**。
    //
    // ⚠️ 「添加待办」的输入框和编辑态的标题框会争同一个焦点 ——
    // 点「修改…」时焦点可能还在添加框上（那个元素被搬进新卡，仍然在 DOM 里），
    // 照旧把它 focus 回去的话，用户点完「修改…」还得再点一下才能打字。
    //
    // 所以：编辑态时，只认编辑态里的输入框；焦点不在编辑态 → 交给标题框。
    var restoredFocus = false;
    var editing = !!DP.editingTodoKey;
    var editTargets = [DP.editTitle, DP.editHour, DP.editMinute];
    var focusInEdit = false;
    for (var fi = 0; fi < editTargets.length; fi++) {
      if (editTargets[fi] && editTargets[fi] === inputFocusTarget) focusInEdit = true;
    }
    if (editing) {
      if (focusInEdit && inputFocusTarget && inputFocusTarget.parentNode) {
        restoredFocus = true;
        setTimeout(function () {
          try { inputFocusTarget.focus(); } catch (e) {}
        }, 0);
      } else if (DP.editTitle && DP.editTitle.parentNode) {
        restoredFocus = true;
        DP.editFocusPending = false;
        DP.editFocusRequested = true;
        setTimeout(function () {
          try { DP.editTitle.focus(); } catch (e) {}
        }, 60);
      }
    } else if (inputHadFocus && inputFocusTarget && inputFocusTarget.parentNode) {
      restoredFocus = true;
      setTimeout(function () {
        try {
          // ⚠️⚠️ **已经有焦点了就别再 focus()**（2026-11-09 修「时间输入不了」）。
          //
          // 在**已经拿到焦点**的 input 上再调一次 `focus()`，
          // WebKit 会走一遍「先失焦再聚焦」——
          // 那个**多余的 blur** 会让网页侧的失焦守卫看到 `activeElement = body`
          // → 判定成「用户离开了输入区」→ `post('textInputBlur')`
          // → 原生退出文本输入模式 → **键盘断掉**。
          //
          // 实测：点「分」框之后 800ms，原生推来一次状态 →
          // `renderPanel` 的焦点还原又 focus 了一次 → 分框立刻失焦 → 键盘没了。
          if (document.activeElement === inputFocusTarget) return;
          if (inputFocusTarget === DP.input) DP.input.focus();
          else inputFocusTarget.focus();
        } catch (e) {}
      }, 0);
    }

    // 内容变了，实心区高度 / 渐变尾巴的起点就得跟着重算。
    // （以前只有 openPanel / positionPanel 会调，于是「添加待办」展开 /
    //   原生异步推来数据之后，尾巴还停在旧位置 —— 又一条缝。）
    layoutFade();
  }

  // 覆盖层可用高度（表头之下的那一列有多高）
  function availableNarrowHeight() {
    var geom = gridGeom();
    if (!geom) return 0;
    return Math.max(0, geom.height - geom.headerBottom);
  }

  // 建一个覆盖层元素（只在需要时建）
  //
  // ⚠️ **元素必须跨 render() 复用** —— 这是「闪烁」的根因。
  //
  // 以前 `render()` 会 `root.innerHTML = ''`，把 `.daypanel` 一起删掉，
  // 之后重建 → **入场动画从头重播**。原生每次推状态都会触发一次 render，
  // 所以鼠标不动面板也会周期性地闪一下；同一列上下移动时更明显
  // （每次经过表头格都会触发一次原生往返）。
  //
  // 现在：render() 之前把元素从旧 grid 上「摘下来」（JS 引用还在），
  // render() 之后重新 append 到**新的** grid —— 同一个元素、
  // 同一份内容节点，动画状态不重置。
  /// 覆盖层挂在谁身上：
  ///   · 展开态 → `.grid`（原来的定位原点）；
  ///   · 折叠态 → **卡片**：`.gridwrap` 只有 38px 高，挂在里面会被裁掉，
  ///     面板要伸到卡片外面，只能挂卡片（`.card` 本身 position: relative）。
  function panelHost() {
    var card = document.querySelector('.ttcard.card');
    if (collapseProgress > 0.5 && card) return card;
    return document.querySelector('.grid');
  }

  function buildPanel() {
    var grid = document.querySelector('.grid');
    var host = panelHost();
    if (!grid || !host) return;

    // 元素还在（可能被 render 摘掉了）→ 复用，只重新挂到新 grid 上。
    if (DP.el) {
      var b = DP.el.querySelector('.dpbody');
      var f = DP.el.querySelector('.dpfade');
      if (b && f) {
        if (DP.el.parentNode !== host) {
          // ⚠️ **挂回去之前先关掉过渡** ——
          // 元素在被摘掉的这段时间里，class 可能被改过（比如摘了 show）。
          // 重新挂上时如果 transition 还在跑，浏览器会把它当成「从旧值过渡到新值」
          // → 入场动画又重播了。
          // `.dpnoreplay` 用 `transition: none !important` 把这一帧的过渡彻底关掉。
          //
          // ⚠️⚠️ **但淡出 / 收起动画正在跑的时候，绝对不能用它**（2026-11 修）。
          //
          // `.dpnoreplay` 的 `transition: none !important` 会把**正在跑的过渡**
          // 一起掐断。淡出时面板的 clip-path 是靠 `.show` 的
          // `transition: clip-path 400ms` 从 `inset(0)` 慢慢插值到
          // `inset(0 0 100% 0)` 的 ——
          //
          //   一旦被掐断 → clip-path **瞬间落到 `.show` 写的 `inset(0)`**
          //   → 面板**整个闪回来一下**，然后过渡没了，它就停在那儿不收了。
          //
          // 实测（逐帧采样）：
          //   105ms  clip=inset(0px 0px 0.1696%)   ← 正在淡出
          //   加 .dpnoreplay 之后
          //          clip=inset(0px)               ← ⚠️ 重置 → 闪一下
          //
          // 用户反馈「淡出收到一半又会突然闪一下再收起」。
          //
          // 所以：**动画在跑时跳过 `.dpnoreplay`** —— 反正这次挂回去
          // 不是为了重放入场动画（面板本来就开着/正在关），过渡该继续就继续。
          var animating = DP.el.classList.contains('closing');
          if (!animating) {
            DP.el.classList.add('dpnoreplay');
          }
          host.appendChild(DP.el);
          // 强制回流，让「无过渡」的终态生效
          void DP.el.offsetHeight;
          if (!animating) {
            DP.el.classList.remove('dpnoreplay');
          }
        }
        DP.grid = grid;
        DP.body = b;
        DP.fade = f;
        return;
      }
      // 结构不对（理论上不会发生）→ 丢掉重建
      DP.el = null;
      DP.body = null;
      DP.fade = null;
    }

    var el = h('div', { class: 'daypanel' },
      h('div', { class: 'dpbody' }),
      h('div', { class: 'dpfade' }));
    host.appendChild(el);
    DP.el = el;
    DP.grid = grid;
    DP.body = el.querySelector('.dpbody');
    DP.fade = el.querySelector('.dpfade');
  }

  // 把覆盖层放到某一列上（按几何定位）
  function positionPanel() {
    if (DP.day === null || !DP.el) return;
    var el = DP.el;
    var host = el.parentNode;
    var grid = DP.grid || document.querySelector('.grid');
    var hdr = document.querySelector('.hcell[data-day="' + DP.day + '"]');
    if (!host || !grid || !hdr) return;

    // 用「宿主 / 表头格」的视口矩形相减 → 宿主坐标系里的位置（CSS px）。
    // 这样不管宿主是 `.grid`（展开）还是 `.card`（折叠）都成立，
    // pageZoom / transform 两种档位也都不用单独判断（除一下倍率即可）。
    var s = layoutScale();
    var hb = host.getBoundingClientRect();
    var cb = hdr.getBoundingClientRect();

    el.style.left = ((cb.left - hb.left) / s) + 'px';
    el.style.top = ((cb.bottom - hb.top) / s) + 'px';
    // 宽度 = 单列宽度（**只有这一种形态**，2026-11 去掉宽态）。
    el.style.width = (cb.width / s) + 'px';
    el.style.right = 'auto';

    // 覆盖层总高 = 满列高（表头之下那一列的高度，版式 px）——
    // 折叠态照旧用这个高度：面板会**伸出卡片**，靠 `.card.collapsed`
    // 的 `overflow: visible` 放行。
    if (!grid.__ttFullH) grid.__ttFullH = grid.offsetHeight;
    var head = 38;
    var full = Math.max(0, (grid.__ttFullH || 0) - head);
    el.style.height = full + 'px';
    // 渐变尾巴：实心区高度自适应，剩下的往下一直渐变到底
    layoutFade();

    // ⚠️ **把面板的真实矩形报给原生**（2026-11）。
    //
    // 悬停判定 / 点击穿透要用「面板到底盖住了哪一块」。原生自己也有一套
    // 几何（`TimetableLayout.dayPanelRect`），但那套只认「展开时的网格」——
    // 折叠 + 缩放 / 不同宿主下会差一点，差出去的那条缝就表现为
    // 「鼠标移到日历上，整个课表淡出」。
    //
    // 这里直接报 `getBoundingClientRect()`（已含 translate / 缩放前的 CSS px），
    // 原生按当前倍率换算成窗口坐标即可，两边永远是同一块矩形。
    // 只报 `getBoundingClientRect()` 原始值：
    //   · transform 档它已经是**视觉** CSS px（含 translate / scale），倍率 1；
    //   · pageZoom 档它是版式 CSS px，原生再乘 pageZoom。
    // 原生用 `testRectScale` 一个系数就够（和 `arrowCenter` 那套换算一致）。
    var pr = el.getBoundingClientRect();
    post('panelRect', { l: pr.left, t: pr.top, w: pr.width, h: pr.height,
                        day: DP.day, open: true });
  }

  // 实心区高度自适应 + 渐变区补到底
  function layoutFade() {
    if (!DP.body || !DP.fade || !DP.el) return;
    var totalH = DP.el.clientHeight;
    // 面板还没定位（高度 0）→ 量不出尾巴，等 positionPanel 再来一次。
    if (!totalH) return;
    // 实心区**最少这么高** ——
    //
    // 内容少的时候（比如没接系统数据，只有「今日无待办」三行），
    // 实心区只有内容那么高，下面一大截全是渐变区，
    // 看上去像「一块半透明的色块」而不是「一个面板 + 瀑布尾巴」。
    //
    // 给一个下限（4 行 ≈ 4×54 = 216pt），面板才有「体量感」，
    // 渐变区也才有「从面板往下溶」的样子。
    var minBody = Math.min(DP_MIN_BODY, totalH);
    // ⚠️ 量「自然内容高度」之前**必须先把 min-height 摘掉**。
    //
    // 以前直接量 offsetHeight：第一次调用把 min-height 设成 216，
    // 第二次调用量到的就是 216（min-height 撑出来的），于是误判成
    // 「内容本来就这么高」→ 把 min-height 清掉 → 实心区缩回内容高度，
    // 而 `--dp-body-h` 还停在 216 → 实心区和渐变尾巴之间裂开一条
    // 140pt 的缝（用户看到的「瀑布不连续」就是这条缝）。
    //
    // 摘掉再量才是**内容自己的**高度；设回去的过程在同一帧内完成，
    // 不会闪。
    DP.body.style.minHeight = '0px';
    var naturalH = DP.body.offsetHeight;
    var bodyH = Math.max(naturalH, minBody);
    DP.body.style.minHeight = bodyH + 'px';
    var tail = Math.max(0, totalH - bodyH);
    DP.fade.style.height = tail + 'px';
    // 实心区高度写进 CSS 变量 —— 渐变尾巴要贴着**实心区底边**开始，
    // 不是贴着面板底边（那样尾巴会跑到面板外面去，看不见）。
    DP.el.style.setProperty('--dp-body-h', bodyH + 'px');
  }

  // 内容装不下时的处理：**面板内滚动**（窄态 / 宽态都一样）。
  //
  // ⚠️ 2026-11 改：窄态以前是「只显示前 N 条 + 「还有 N 条」」，
  // 现在**一条都不截断** —— 装不下就在面板里滚。
  //
  // 为什么滚动条要挂在 `.dpbody` 上：
  //   · `.dpbody` 就是实心区，滚它 = 滚「有内容的那一块」，
  //     底板本身不动，视觉上不会整块漂移；
  //   · 内容不够长时 `overflow-y: auto` **不会**出现滚动条
  //     （auto 只在溢出时才显示）—— 满足「内容不长时不要出现滚动条」。
  function applyNarrowLimit() {
    if (!DP.body) return;
    // 上限 = 那一列在表头之下还剩多少高度
    //（实心区高度是自适应的，只是不能超出这一列 ——
    //  超出的话渐变尾巴就没有落脚点了）。
    var room = availableNarrowHeight();
    DP.body.style.maxHeight = (room > 0 ? room : DP_NARROW_MAX) + 'px';
    DP.body.classList.add('narrow');
    // ⚠️ **窄态也要能滚** —— 内容超高时面板内滚动，不截断条目。
    DP.body.classList.add('scroll');
  }

  // 滚轮 / 触控板：落在面板上时**滚面板**，不要穿透到背后的课表。
  //
  // ⚠️ 桌面层窗口的滚动是原生转发的（`WheelForwardingScrollView`），
  // 网页这边必须把 `wheel` 事件的默认行为吃掉，否则：
  //   · 页面会跟着一起滚（课表整体移位）；
  //   · 原生那边还会把滚轮转发给下层的课表视图 → 课表格被滚走。
  //
  // 装在**捕获阶段**（`true`）—— 冒泡阶段可能已经被别处处理了。
  // 只在「指针确实落在覆盖层上」时才干预，面板外的滚轮照常。
  document.addEventListener('wheel', function (e) {
    if (!DP.open || !DP.body) return;
    var t = e.target;
    if (!t || !t.closest) return;
    if (!t.closest('.daypanel')) return;      // 不在面板上 → 不管
    // 面板本身不能滚（内容没溢出）→ 让原生去滚课表（正常行为）。
    var canScroll = DP.body.scrollHeight > DP.body.clientHeight + 1;
    if (!canScroll) return;
    // 内容已经滚到头 / 尾，且滚轮继续往那个方向 → **不拦**
    //（让原生继续滚课表，否则用户永远滚不动课表）。
    var atTop = DP.body.scrollTop <= 0;
    var atBottom = DP.body.scrollTop + DP.body.clientHeight >= DP.body.scrollHeight - 1;
    var delta = e.deltaY;
    if ((delta < 0 && atTop) || (delta > 0 && atBottom)) return;
    // 拦下来：滚面板，并把滚动位置给面板。
    e.preventDefault();
    e.stopPropagation();
    DP.body.scrollTop += delta;
  }, { capture: true, passive: false });

  // ---- 打开 / 关闭 ----

  // 动画时长（毫秒）—— 与 CSS 里的值**必须一致**。
  //
  // 打开 = 600ms（自上而下铺开），收起 = 400ms（自下而上收拢）。
  var DP_OPEN_MS = 600;
  var DP_CLOSE_MS = 400;
  // 完成待办后「缓慢消失」的时长（和 CSS `.dpcard.todo.leaving` 的
  // `dpTodoLeave` 动画保持一致）。
  var DP_LEAVE_MS = 400;

  function nowMs() {
    return (window.performance && typeof performance.now === 'function')
      ? performance.now() : Date.now();
  }

  // 在 render() 动手之前，把**正在播的入场动画**当前进度记下来。
  //
  // 为什么需要：原生打开覆盖层后立刻会推状态 → render() → 整张卡重建。
  // `.daypanel` 元素虽然被复用，但「从旧 grid 摘下 → 挂到新 grid」会
  // **取消正在跑的 transition**；buildPanel 里为了防重播还会加
  // `.dpnoreplay`（transition:none），于是 clip-path 直接跳到终态 ——
  // 600ms 的瀑布被截成不到一帧，用户看到的还是「唰一下就出来」。
  //
  // 记下当时的 clip-path 和 opacity，挂回去之后从这两个值**接着播**
  // 剩下的时长，动画就不会被打断。
  function capturePanelEntrance() {
    if (!DP.el || !DP.open || !DP.el.classList.contains('show')) return null;
    var elapsed = nowMs() - DP.openedAt;
    if (!(elapsed >= 0 && elapsed < DP_OPEN_MS)) return null;
    var ce = getComputedStyle(DP.el);
    return {
      elapsed: elapsed,
      clip: ce.clipPath || ce.webkitClipPath || '',
      opacity: ce.opacity || ''
    };
  }

  // 挂回新 grid 之后，从 capturePanelEntrance() 记下的进度接着播。
  function resumePanelEntrance(st) {
    if (!st || !DP.el || !DP.open) return;
    var remain = DP_OPEN_MS - (nowMs() - DP.openedAt);
    if (remain <= 0) return;
    var el = DP.el;

    // ⚠️ **起始值 `inset(...100%)` 也要接着播**。
    //
    // 原生推状态来得很快（< 30ms），这时动画常常还停在第一帧，
    // 采样到的就是起始值。以前把它当成「没开始 / 不可续播」直接跳过，
    // 结果挂回新 grid 时 `.dpnoreplay` 把 clip 直接落到终态 ——
    // 实测 52ms 就已经是 `inset(0)`，600ms 的瀑布等于没有。
    var hasClip = !!(st.clip && st.clip !== 'none');
    var op = st.opacity ? parseFloat(st.opacity) : NaN;
    var hasOp = isFinite(op) && op >= 0 && op < 0.99;
    if (!hasClip && !hasOp) return;

    // ① 先把 clip / opacity 钉在「当时已经播到哪」，关掉过渡强制回流
    el.style.transition = 'none';
    if (hasClip) {
      el.style.clipPath = st.clip;
      el.style.webkitClipPath = st.clip;
    }
    if (hasOp) el.style.opacity = st.opacity;
    void el.offsetHeight;

    // ② 再一起用**剩余时长**走到终态（600ms 的瀑布不会重头开始）
    var props = [];
    if (hasClip) props.push('clip-path ' + remain + 'ms cubic-bezier(0.2, 0.85, 0.3, 1)');
    if (hasOp) props.push('opacity ' + remain + 'ms ease');
    el.style.transition = props.join(', ');
    if (hasClip) {
      el.style.clipPath = '';
      el.style.webkitClipPath = '';
    }
    if (hasOp) el.style.opacity = '';

    // 播完把内联 transition 摘掉，下次开关继续走 CSS 的 600 / 400。
    setTimeout(function () {
      if (DP.el === el) el.style.transition = '';
    }, remain + 60);
  }

  // 清掉面板上的 Web Animations 动画（反向续播用的）。
  // 残留的 WAAPI 动画（fill: forwards）优先级高于 CSS 过渡，
  // 不 cancel 会压住之后 `.closing` 的收起过渡。
  function clearPanelAnimations(el) {
    if (el && el.getAnimations) {
      try { el.getAnimations().forEach(function (a) { a.cancel(); }); } catch (e) {}
    }
  }

  function openPanel(day, autoRequest) {
    if (!day || day < 1 || day > 7) return;
    // ⚠️ **收拢动画还在播**（鼠标离开 / 点击关闭后 400ms 内又触发打开）。
    //
    // 不能直接摘 `.closing` 重开：clip-path 会从「收了一半」**瞬间跳回**全开
    // （用户看到的「收到一半突然又长回去」）。
    // 也不能等 400ms 再开：跟随模式下移回列应该**立即**出现。
    //
    // 正确做法：从**当前收拢进度反向续播** —— 先采样当前 clip-path，
    // 移除 `.closing`，用 Web Animations API 从当前值播到全开 `inset(0)`。
    // 视觉上「收拢中 → 无缝反向展开」，没有跳变。
    if (DP.closing && DP.el) {
      var el0 = DP.el;
      var curClip = getComputedStyle(el0).clipPath;
      el0.classList.remove('closing');
      if (curClip && curClip.indexOf('inset') === 0 && el0.animate) {
        try {
          var rev = el0.animate(
            [{ clipPath: curClip }, { clipPath: 'inset(0px)' }],
            { duration: DP_CLOSE_MS, easing: 'cubic-bezier(0.2, 0.85, 0.3, 1)',
              fill: 'forwards' }
          );
          rev.onfinish = function () { clearPanelAnimations(el0); };
        } catch (e) { /* WAAPI 不可用 → 直接切，等同旧行为 */ }
      }
      DP.closing = false;
      DP.closingDay = null;
    }
    // 打开 = 进入跟随模式（之后指针移到别的列，面板会跟过去）
    DP.following = true;
    if (DP.day !== null && DP.day !== day) resetTodoEditState();
    DP.day = day;
    DP.open = true;
    // ⚠️ **清掉「正在关闭」**（2026-11 修）——
    // 新打开的面板取代了正在关闭的那个，收起动画的收尾会作废
    // （token 对不上），这里同步把标志清掉，
    // 否则下一次点击会被 `DP.closing` 拦掉。
    DP.closing = false;
    DP.closingDay = null;
    DP.token++;      // 新面板 → 上一轮收拢的收尾自动作废
    // ⚠️ **数据缺失补发请求**（2026-11）——
    //
    // 点击打开时 onHeaderPick 已发 `datePanelOpen`，原生查数据推回；
    // 但**跟随模式鼠标换列**只调 openPanel、不发 intent → 目标列数据
    // 若从未被原生推过（S.dayPanel 对不上、缓存也没有）→
    // 待办 / 日历 / 今日详情全空（用户：带红点的列移过去待办不显示）。
    //
    // ⚠️ **判断「有没有数据」必须看 `DP.loaded`，不能看 `panelDataFor()`**
    // （2026-11 修）：`panelDataFor()` 有「只有今日详情」的兜底，永远非空，
    // 于是这个请求**永远不会发** —— 换到别的周再回来，跟随打开某一列时
    // 只有农历、没有待办 / 日程，必须再点一下日期才更新
    // （用户反馈：「不会第一时间显示，要再点一下」）。
    // `DP.loaded` 只记原生明确 `ready: true`（EventKit 查完并合并过）的列。
    //
    // `DP.requestedDay` 防同一列被 mousemove 高频重复请求；
    // `autoRequest === false` 是自检 / 出图直接注入状态的路径，不往原生要数据。
    if (autoRequest !== false && DP.requestedDay !== day && !DP.loaded[day]) {
      DP.requestedDay = day;
      post('datePanelOpen', { day: day });
    }
    buildPanel();
    if (!DP.el) return;
    // ⚠️ **取消上一次打开留下的兜底定时器**（2026-11）。
    //
    // 不取消的话，它会在**这次**打开的揭开动画刚起步时触发 ——
    // 那时 clip-path 还在起始帧 `100%`，它会误判成「动画没跑」→
    // 加上 `.dpnoplay`（clip-path: none）→ 面板**瞬间整个出现**，
    // 之后又摘掉 → 揭开动画重播 → 用户看到「突然出现 → 渐渐出现」。
    if (DP.openFallbackTimer) {
      clearTimeout(DP.openFallbackTimer);
      DP.openFallbackTimer = null;
    }
    clearPanelAnimations(DP.el);
    // 上一次的收起动画可能还没播完（快速再点一次）——
    // 这个类会压住 `.show`（`.closing` 的 clip 在样式表里更靠后），
    // 不清掉的话新面板会「开着但完全被裁掉」，看起来像点不开。
    // ⚠️ **`.dpnoplay` 也要摘掉** ——
    // 那是「上一轮动画没跑」的兜底（clip-path: none）。
    // 留着它 → 打开的揭开动画（inset(0)）被压住 → **看不到揭开动画**。
    DP.el.classList.remove('closing', 'dpnoplay');
    positionPanel();      // 先定位（宽度/高度），量高度才准
    renderPanel();
    applyNarrowLimit();

    // ⚠️ **已经开着的时候（换列 / 跟随）不要重放入场动画。**
    //
    // 以前每次都 `classList.remove('show')` → `add('show')`，
    // 于是「换列」= 旧面板淡出 + 新面板重放入场 —— 观感上就是闪一下。
    // 现在：元素一直在，class 一直是 show，只是**位置和内容**变了。
    //
    // ⚠️ **但「收走过之后再打开」必须重新播入场动画**（2026-11 修）。
    //
    // 收起动画结束时只摘了 `.closing`，**`.show` 还在** ——
    // 于是 `wasShown` 一直是 true → 下面那段（重新加 `.show`、
    // 刷新 `DP.openedAt`）**整个被跳过** → 揭开动画根本没重新开始：
    //   · clip-path 停在收起后的 `inset(0 0 100% 0)` → 面板是裁掉的；
    //   · 兜底定时器（`DP.openedAt` 还是上一次的旧值）判定「动画没跑」
    //     → 加上 `.dpnoplay`（clip-path: none）→ **面板瞬间整个出现**
    //     （用户看到的「突然出现」）；
    //   · 之后 `.dpnoplay` 被摘掉 → 揭开动画又重播 → **「渐渐出现」**。
    //
    // 也就是说用户说的「应该是要显示，但不是要这么闪一下」。
    //
    // 判据：**面板现在是「收走的状态」**（`DP.open` 刚被置 true，
    // 但上一次是收走的）→ 要重新播入场动画。
    var wasShown = DP.el.classList.contains('show');
    if (wasShown && DP.reopening) {
      // 重新打开：先把 `.show` 摘掉 → 强制走一遍入场动画。
      //
      // ⚠️ 摘 `.show` 会让 clip-path 回到基础规则的 `inset(0 0 100% 0)`，
      // 下一行再加回 `.show` 就会产生 600ms 的揭开过渡。
      DP.el.classList.remove('show');
      wasShown = false;
    }
    DP.reopening = false;
    if (!wasShown) {
      // 强制回流一次，保证 clip-path 的入场动画能跑起来。
      //
      // ⚠️ **必须读 `.dpbody` 的高度**，不能读 `.daypanel` 的 ——
      // clip-path 是在 `.dpbody` 上的，读父容器的高度**不会**让子元素的
      // clip-path 重新计算，结果动画不启动，面板永远停在「完全裁掉」的状态
      // （看起来就是什么也没有）。
      //
      // 不用 requestAnimationFrame —— 原生推状态时可能在同一帧里连着调好几次，
      // rAF 会把「点亮」推到下一帧，快照模式下就拍不到刚出现的样子。
      if (DP.body) { void DP.body.offsetHeight; }
      DP.el.classList.add('show');
      // 入场动画从此开始计时 —— render() 打断时按剩余时长接着播。
      DP.openedAt = nowMs();
    }

    // ⚠️ **兜底：动画不跑时也要能看见。**
    //
    // CSS transition 靠**合成器**推进。合成器不跑的时候（窗口不可见、
    // 离屏渲染、快照模式拍图），transition 会**永远停在起始帧** ——
    // 面板就完全看不见。
    //
    // 这里给一个「动画没跑就手动落到终态」的兜底：
    // 等一小段时间后如果 clip-path 还停在 `inset(..., 100%, ...)`，
    // 说明动画没跑 → 加一个 `.dpnoplay` 类（CSS 里 = `clip-path: none`）。
    //
    // ⚠️⚠️ **必须用类，不能用 inline style**（2026-11 修）：
    //
    // 以前这里写的是 `elRef.style.clipPath = 'none'` ——
    // **inline 样式的优先级比任何 class 都高**，
    // 于是它会**永久**压住 CSS 里的 `clip-path`：
    //   · `.closing`（收起动画）的 `inset(0 0 100% 0)` **完全失效**
    //     → 用户反馈「再点一次关闭覆盖层的时候没有消失的动画」；
    //   · `.show`（打开动画）的 `inset(0)` 也一样失效。
    //
    // 改成类之后，`.dpnoplay` 和 `.show` / `.closing` 优先级相同，
    // **谁赢由 CSS 里的先后顺序决定** ——
    // 我们把 `.dpnoplay` 放在 `.closing` **之后**：
    //   · 兜底时（动画没跑）→ `.dpnoplay` 生效 → 面板看得见；
    //   · 收起时 → 摘掉 `.dpnoplay` → `.closing` 的动画正常播。
    if (DP.body) {
      var elRef = DP.el;
      DP.openFallbackTimer = setTimeout(function () {
        DP.openFallbackTimer = null;
        if (!elRef || !elRef.parentElement) return;
        if (!elRef.classList.contains('show')) return;
        // ⚠️ **动画可能已经被别的东西重置过了**（2026-11 修）。
        //
        // 以前这里只看「clip-path 是不是还停在 100%」就加兜底类。
        // 但用户**很快**点关闭再点开时，面板会重新加 `.show` ——
        // 这时上一次的兜底定时器也还在，它会把**正在播的动画**打断
        // （直接跳到终态）→ 用户看到的是「揭开动画没了」。
        //
        // 所以先确认「**这次**打开的动画确实该结束了」——
        // `DP.openedAt` 是本次打开的时刻，超过 `DP_OPEN_MS` 才算该结束了。
        var elapsed = nowMs() - DP.openedAt;
        if (!(elapsed >= DP_OPEN_MS)) return;
        // clip-path 现在做在 `.daypanel` 上（实心区 + 渐变尾巴一起揭开）。
        var cp = getComputedStyle(elRef).clipPath || getComputedStyle(elRef).webkitClipPath;
        // 还停在「完全裁掉」→ 动画没跑。
        if (cp && cp.indexOf('100%') >= 0) {
          elRef.classList.add('dpnoplay');
        }
        // **容器自己的 opacity 也要兜底** —— 它也有 transition，
        // 合成器不跑时同样会停在起始值 0（面板整个看不见）。
        //
        // ⚠️ **不要写 inline 的 `style.transition = 'none'`**（2026-11 修）：
        // inline 样式的优先级比任何 class 都高，会**永久**关掉面板上
        // **所有**过渡 —— 包括关闭时的收起动画。
        // 用户反馈「再点一次关闭覆盖层的时候没有消失的动画」就是它造成的。
        //
        // 这里只把 opacity 钉到 1，**不动 transition** ——
        // 兜底本来就是「动画没跑」的情况，transition 反正也不动。
        var op = getComputedStyle(elRef).opacity;
        if (op && parseFloat(op) < 0.99) {
          elRef.style.opacity = '1';
        }
      }, DP_OPEN_MS + 200);
    }
    layoutFade();
    syncHeaderSel();
  }

  // 鼠标离开课表 / 移到时间列：面板消失。
  //
  // ⚠️ **和点击关闭（closePanel）共用同一种收拢动画**（2026-11 统一）——
  // 以前这里是 `.fading` 透明度淡出，和 `.closing` 收拢**两套并存**，
  // 互相抢状态：淡出播到一半被 openPanel 摘掉 `.fading` → opacity 回弹
  // （就是「收到一半 → 突然又长回去」）。
  //
  // 现在统一：消失一律播 `.closing` 收拢动画（淡出 + 自下而上收拢），
  // 两套并存的冲突直接消除。与 closePanel 的唯一区别：
  // **保持跟随模式**（following 不变），移回任一列会重新出现；
  // 点击关闭则退出跟随（见 closePanel）。
  //
  function fadeOutPanel() {
    if (!DP.el || !DP.open) {
      DP.open = false;
      DP.day = null;
      syncHeaderSel();
      return;
    }
    var wasDay = DP.day;
    DP.open = false;
    DP.day = null;
    DP.adding = false;
    resetTodoEditState();
    DP.closing = true;
    DP.closingDay = wasDay;
    // ⚠️ **下一次打开要重新播入场动画**（2026-11）。
    //
    // 收起动画只摘 `.closing`，`.show` 还在 → 下次打开时
    // `wasShown` 一直为 true → 入场动画被整个跳过 →
    // 面板卡在裁掉的状态，直到兜底定时器加 `.dpnoplay` 才**瞬间出现**
    // （用户说的「突然出现 → 渐渐出现」）。
    DP.reopening = true;
    syncHeaderSel();
    runCloseAnimation(wasDay);
  }

  // 公共收拢动画：加 `.closing` 类播 400ms 收起，播完清理。
  // fadeOutPanel（鼠标离开，保持跟随）和 closePanel（点击关闭，退出跟随）共用。
  // token 防止「收拢期间又打开新面板」时被误清理。
  function runCloseAnimation(wasDay) {
    if (!DP.el) {
      // ⚠️ **没有面板可收时也要把「正在关闭」清掉**（2026-11 修）。
      //
      // `closePanel` 先置 `DP.closing = true`，再调这里；
      // 这里如果直接 return，标记就永远是 true ——
      // 之后 `ttUpdate` 里 `panelAnimating = DP.closing` 一直成立，
      // **所有整树重画都被跳过**：切周 / 加课 / 删课都不更新，
      // 要等下一次面板开合才补上（用户：「过很久才逐渐显示」）。
      //
      // 折叠时会无条件 `closeDayPanel()`，所以这个坑是折叠功能暴露出来的。
      DP.closing = false;
      DP.closingDay = null;
      return;
    }
    var token = ++DP.token;
    var el = DP.el;
    // ⚠️ 先清掉反向续播的 WAAPI 动画 ——
    // 残留的 fill:forwards 会压住 `.closing` 的收起过渡（WAAPI 优先级更高）。
    clearPanelAnimations(el);
    // ⚠️ **`show` 立刻摘掉**，`closing` 自己负责可见性
    // （见 CSS 里 `.daypanel.closing` 的说明）。
    // ⚠️ **摘掉 `.dpnoplay`** ——
    // 那是「动画没跑」的兜底（clip-path: none）。
    // 留着它的话，收起动画的 `inset(0 0 100% 0)` 会被压住 → **看不到收起动画**。
    el.classList.remove('show', 'dpnoplay');
    // ⚠️ **同时清掉 inline 的 transition** ——
    //
    // `resumePanelEntrance()` 会在接管动画时写一个 inline 的 `transition`，
    // 播完才摘掉。如果用户在**它还没播完**的时候就关闭面板，
    // 这个 inline 值会**留下来** → 之后所有过渡都被关掉
    // → **收起动画、揭开动画全都没有**（用户反馈「没有消失的动画」）。
    //
    // inline 的优先级比 class 高，所以必须**显式清掉**，
    // 不能靠「等它自己摘」。
    el.style.transition = '';
    el.classList.add('closing');
    // 强制回流，让 `.closing` 的终态（收拢）生效
    void el.offsetHeight;
    setTimeout(function () {
      // 期间又打开了新的面板 → 这次收尾作废（不能把新面板清掉）
      if (DP.token !== token) return;
      if (DP.el === el) {
        el.classList.remove('closing');
        el.style.height = '0px';
        el.style.setProperty('--dp-body-h', '0px');
      }
      // ⚠️ **收起动画播完 → 解除「正在关闭」**（2026-11 修）。
      //
      // 不清的话，用户在动画播完之后再点那个日期就**没反应**了
      // （`DP.closing` 一直是 true → 点击一直被忽略）。
      DP.closing = false;
      DP.closingDay = null;
      // 面板真的收起了 → 这时候才摘表头选中态（见 syncHeaderSel 的说明：
      // 收起动画期间要保留，否则鼠标短暂离开再回来会让表头一暗一亮）。
      syncHeaderSel();
    }, DP_CLOSE_MS);
  }

  function closePanel(quiet) {
    // 彻底关闭（点日期 / 拖动课表）→ 退出跟随模式。
    //
    // 和 `fadeOutPanel` 的区别：鼠标离开只是「看不见了」（指针移出课表 /
    // 移到时间列），跟随模式还在，移回来会继续出现；这里是用户明确关掉，
    // 之后悬停不再打开，直到下一次点日期。
    //
    // ⚠️ **和 fadeOutPanel 共用同一种收拢动画**（2026-11 统一）。
    DP.following = false;
    // 先记住是哪一列 —— 下面要把 DP.day 清掉，
    // 收尾的 datePanelClose 得带上原来的 day（契约要求 payload.day 是 1…7）。
    var wasDay = DP.day;
    DP.open = false;
    DP.day = null;
    DP.adding = false;
    resetTodoEditState();
    // ⚠️ **标记「正在关闭」**（2026-11 修）。
    //
    // 收起动画要播 400ms，这期间用户可能又点了一下同一个日期 ——
    // 以前 `DP.open` 已经是 false，那个点击会被当成「打开」→ 面板又弹出来。
    //
    // 这个标志让那期间的点击**被忽略**。
    DP.closing = true;
    DP.closingDay = wasDay;
    if (!quiet && wasDay) post('datePanelClose', { day: wasDay });
    syncHeaderSel();
    runCloseAnimation(wasDay);
  }

  // 表头选中态
  function syncHeaderSel() {
    var cells = document.querySelectorAll('.hcell[data-day]');
    // ⚠️ **收起动画期间高亮要留到动画播完**（2026-11 修「表头一暗一亮」）。
    //
    // 现象：点完待办、鼠标稍微一晃，指针有一瞬间被判成「不在这一列」
    // → `fadeOutPanel` 当场摘掉 `.sel` → 表头文字开始 200ms 褪色；
    // 下一帧指针又被判成「回来了」→ `openPanel` 加回 `.sel` → 又变白。
    // 褪到一半再回来，用户看到的就是「暗 → 亮 → 暗 → 亮」。
    //
    // 面板还在屏幕上收拢（400ms 内）时，那一列本来就还是「被查看的」，
    // 高亮不该提前掉。真正的收起播完（`runCloseAnimation` 的收尾）才摘 ——
    // 短暂的离开/回来不会让 `.sel` 变化，颜色过渡也就不会重播。
    //
    // 注意：过渡本身**保留**（打开 / 换列时那一下渐变是想要的）。
    var onDay = DP.open ? DP.day : (DP.closing ? DP.closingDay : null);
    for (var i = 0; i < cells.length; i++) {
      var d = parseInt(cells[i].getAttribute('data-day'), 10);
      if (onDay !== null && d === onDay) cells[i].classList.add('sel');
      else cells[i].classList.remove('sel');
    }
  }

  // 只更新表头的小红点 / 小橙点，**不重建表头 DOM**（2026-11 修「闪几下」）。
  //
  // 以前每次 `ttUpdate` 都走 `render()` → `root.innerHTML = ''` →
  // 表头格（含周四的蓝色选中底）全部重建。完成一条待办会连续推 2～4 次
  // 状态，于是表头就跟着闪几下。
  function applyHeaderFlags() {
    var cells = document.querySelectorAll('.hcell[data-day]');
    var allWeeks = isAllWeeksMode();
    for (var i = 0; i < cells.length; i++) {
      var cell = cells[i];
      var d = parseInt(cell.getAttribute('data-day'), 10);
      if (!(d >= 1 && d <= 7)) continue;
      var flags = dayFlagsOf(d);
      var hasTodo = !allWeeks && !!(flags && flags.todo);
      var hasEvent = !allWeeks && !!(flags && flags.event);
      var hasDiary = !allWeeks && !!(flags && flags.diary);

      var mid = cell.querySelector('.hmid');
      var row = cell.querySelector('.hdrow');
      if (!mid || !row) continue;
      // ⚠️ **只切换 `.off`，不要插 / 摘节点**（2026-11 修「表头闪一下」）。
      //
      // 插 / 摘节点会让「周一」两个字左右跳一下；切换可见性则位置不动。
      // 老页面（没有占位节点）兜底补一个，保证逻辑仍然成立。
      var todoDot = row.querySelector('.dot.todo');
      if (!todoDot) {
        todoDot = h('span', { class: 'dot todo off' });
        row.insertBefore(todoDot, row.firstChild);
      }
      if (hasTodo) todoDot.classList.remove('off');
      else todoDot.classList.add('off');

      var diaryDot = mid.querySelector('.dot.diary');
      if (diaryDot) {
        if (hasDiary) diaryDot.classList.remove('off');
        else diaryDot.classList.add('off');
      }

      var eventDot = mid.querySelector('.dot.event');
      if (!eventDot) {
        eventDot = h('span', { class: 'dot event off' });
        mid.appendChild(eventDot);
      }
      if (hasEvent) eventDot.classList.remove('off');
      else eventDot.classList.add('off');
    }
    syncHeaderSel();
  }

  // 对象属性的**稳定**文本化（键按字典序排）。
  //
  // ⚠️ 指纹不能直接用 `JSON.stringify`（2026-11 修「点日期 / 点完成表头一暗一亮」）。
  //
  // 根因（实测）：原生用 `JSONSerialization` 序列化 Swift 字典，**键的顺序
  // 不保证每次一样** —— 实测连续三次推送里，`courses` / `periods` 的
  // 值完全相同，但键序不同 → 文本不同。
  // `JSON.stringify` 保留键序，于是指纹跟着变 → 明明没改数据也判成
  // 「课表变了」→ `ttUpdate` 走整树 `render()` → 表头格重建 →
  // 新节点上再挂 `.sel` → 文字重新从 42% 暗色渐变到白色。
  // 原生一次交互会推好几次（打开面板 3 次、完成待办 2～4 次），
  // 用户看到的就是「暗 → 亮 → 暗 → 亮」。
  //
  // 所以指纹必须**与键序无关**：按字典序把键排好再序列化。
  function stableText(v) {
    if (v === null || typeof v !== 'object') return JSON.stringify(v);
    if (Array.isArray(v)) {
      var parts = [];
      for (var i = 0; i < v.length; i++) parts.push(stableText(v[i]));
      return '[' + parts.join(',') + ']';
    }
    var keys = Object.keys(v).sort();
    var out = [];
    for (var k = 0; k < keys.length; k++) {
      out.push(JSON.stringify(keys[k]) + ':' + stableText(v[keys[k]]));
    }
    return '{' + out.join(',') + '}';
  }

  // 表格本身的「指纹」——这些字段变了才需要整张表重建。
  //
  // `dayPanel` / `dayFlags` / `dayFestivals` / `dayPanelOpen` 只影响
  // 覆盖层和表头小圆点，走轻量更新就够了。
  //
  // ⚠️ 时钟 / 状态条**不在这里**（2026-11 修「时间停在半小时前」）：
  // 它们由网页自己的 `updateLiveTexts()` 每 10 秒就地更新。
  // 以前这里塞过 `Math.floor(Date.now() / 60000)`，想靠「跨分钟」触发重绘，
  // 但新旧两个指纹是**同一时刻**算的 → 分钟项永远相等，从没起过作用。
  function tableStateKey(o) {
    if (!o) return '';
    return stableText([
      o.courses, o.periods, o.semesterStart,
      o.currentWeek, o.viewWeek, o.maxWeek, o.overrides,
      o.title, o.subtitle
    ]);
  }

  // ---- 表头点击 / 双击 ----

  function onHeaderPick(day) {
    // ⚠️ 折叠态**不再先展开**（2026-11 用户要求）：
    // 点日期直接弹日期覆盖层（日历 + 待办），面板从折叠条底下伸出来。
    // 以前是「先展开，展开完原生再打开面板」—— 用户觉得「点个日期课表先跳开」很别扭。
    // 再点**同一列**的日期 → 直接关闭（窄态宽态都算）。
    //
    // ⚠️ 以前这里有个条件（只在宽态才关）—— 窄态下再点同一列只会
    // 「重新打开一遍」，面板永远收不回去，用户以为按钮坏了。
    //
    // 规格是「再点同一列的日期 = 直接关闭」。
    if (DP.closing && DP.closingDay === day) {
      // ⚠️ **收起动画正在播** → 忽略**同一列**的这次点击。
      //
      // 以前这里只看 `DP.open`（关闭时立刻置 false），
      // 于是动画播到一半再点一次 → 被当成「打开」→ 面板又弹出来
      // （用户反馈「要点几次才能收起来」）。
      //
      // ⚠️ **只拦同一列**（`closingDay === day`）——
      // 拦掉所有列的话，「关掉这一列之后点别的列」也会被吞掉
      // （自检实测：点另一个日期 → 覆盖层没能重新打开）。
      return;
    }
    if (DP.open && DP.day === day) {
      post('datePanelClose', { day: day });
      closePanel(true);
      return;
    }
    // ⚠️ **「全部周次」模式下不弹覆盖层**（2026-11）。
    //
    // 全部周次 = 所有教学周的课程叠在一起看，
    // 这时「周三」指哪一天是**没有定义的**（一学期有十几个周三）——
    // 显示任何一天都是错的。
    //
    // 用户确认的行为：这时候点日期**什么都不弹**。
    if (isAllWeeksMode()) {
      post('datePanelOpen', { day: day });
      return;
    }
    // 点**别的列** → 切到那一列。
    post('datePanelOpen', { day: day });
    // ⚠️ 标记已请求 —— openPanel 里的「数据缺失补发」逻辑看到
    // requestedDay === day 就不会重复发（点击路径已经发了）。
    DP.requestedDay = day;
    DP.adding = false;
    resetTodoEditState();
    openPanel(day);
  }

  // ⚠️ **原来的 `onHeaderDouble()`（双击撑开）已删**（2026-11）。
  //
  // 双击表头曾经会把面板撑成一个浮在课表格上的大方块 ——
  // 盖住旁边的列、底边是硬边、和底板「往下溶」的瀑布不搭，
  // 而且卡片化 + 面板内滚动之后，宽态也没多显示什么。
  //
  // 现在**只有一列宽**这一种形态，内容装不下就在面板里滚。


  // ---- 鼠标状态机 ----

  // 指针在课表里的哪一列？（不在任何列返回 null）
  //
  // 注意覆盖层本身：面板显示时是 pointer-events:auto，
  // 指针落在面板上时 elementFromPoint 返回的是面板里的元素，
  // 不是下面的课程格 —— 直接返回 null 的话，
  // 鼠标一碰到面板覆盖层就淡出消失了（面板正好盖住那一列的课表格）。
  // 所以先判断：落在面板上 → 就当还在这一列。
  function dayAtPoint(clientX, clientY) {
    var el = document.elementFromPoint(clientX, clientY);
    if (!el) return null;
    if (el.closest) {
      // 命中覆盖层 → 还是那一列
      var dp = el.closest('.daypanel');
      if (dp && DP.day !== null) return DP.day;
      // ⚠️ **表头格也算那一列**。
      //
      // 以前只认 `.cell[data-day]`（网格里的课程格），表头格 `.hcell`
      // 不在其中 → 鼠标从网格往上移到日期上时，`dayAtPoint` 返回 null
      // → 覆盖层淡出消失。
      //
      // 但表头本来就是这一列的标签 —— 鼠标停在「周五 30」上时，
      // 覆盖层就该还在（否则用户点完日期、手一抬上去面板就没了）。
      var hcell = el.closest('.hcell[data-day]');
      if (hcell) {
        var hd = parseInt(hcell.getAttribute('data-day'), 10);
        return (hd >= 1 && hd <= 7) ? hd : null;
      }
    }
    var cell = null;
    if (el.closest) cell = el.closest('.cell[data-day]');
    if (cell) {
      var d = parseInt(cell.getAttribute('data-day'), 10);
      return (d >= 1 && d <= 7) ? d : null;
    }
    // ⚠️ **兜底：按「列」的几何位置判断，而不是只认格子。**
    //
    // 课程格之间有间距（行与行、格子与格子之间有空隙），指针从日期往下
    // 移动时会「掉进缝里」—— 这时 `elementFromPoint` 返回 `.grid` 本身，
    // 上面那套 DOM 判断全部落空 → 返回 null → 覆盖层当场淡出。
    // 用户看到的就是「点开之后鼠标往下一移，瀑布就没了」。
    //
    // 覆盖层跟着的是**整列**（表头底边到网格底边），不是某一个格子。
    // 所以拿表头格的水平范围当列的边界，纵向落在这条网格带里就算那一列。
    var gridEl = document.querySelector('.grid');
    if (!gridEl) return null;
    var gr = gridEl.getBoundingClientRect();
    // ⚠️ **指针在网格上方（顶栏 / 状态条那一带）时，别把面板收走**。
    //
    // 用户实测：点开某一列 → 指针往上移到「日历上方」（表头上面的
    // 时钟 / 状态条区域）→ **面板立刻收进去了** → 再从顶上往下滑回
    // 表头 → 面板又「突然出现」。
    //
    // 那个区域**还在课表卡片里**（顶栏是卡片的一部分），指针并没有
    // 离开课表 —— 面板不该收。
    //
    // 判定：纵向在网格上方、横向落在**当前那一列**的范围里
    // → 认定还是这一列（`DP.day`），面板不动。
    if (clientY < gr.top) {
      if (DP.day !== null) {
        var curHead = gridEl.querySelector('.hcell[data-day="' + DP.day + '"]');
        if (curHead) {
          var chr = curHead.getBoundingClientRect();
          if (clientX >= chr.left - 3 && clientX <= chr.right + 3) {
            return DP.day;
          }
        }
      }
      return null;
    }
    if (clientY > gr.bottom) return null;
    var heads = gridEl.querySelectorAll('.hcell[data-day]');
    // ⚠️ 列与列之间有 6px 的 grid gap —— 指针落在**列缝**里时，
    // elementFromPoint 只命中 `.grid`，上面 DOM 判定全落空。
    // 以前缝隙不在任何表头格范围内 → 返回 null（"不在任何列"）→
    // `onPointerMove` 触发 `fadeOutPanel` → 面板开始收拢；
    // 鼠标一晃回列内 → 又 `openPanel` → 反复「收拢 ↔ 展开」，
    // 动画每帧被重置 —— 就是用户看到的「同一列内移动一直闪」。
    // 修法：每列的命中范围向左右各扩 gap/2（3px），列缝归最近的列。
    for (var i = 0; i < heads.length; i++) {
      var hr = heads[i].getBoundingClientRect();
      if (clientX >= hr.left - 3 && clientX <= hr.right + 3) {
        var gd = parseInt(heads[i].getAttribute('data-day'), 10);
        return (gd >= 1 && gd <= 7) ? gd : null;
      }
    }
    return null;
  }

  // 指针是否还在课表卡片范围内
  DP.pointer = null;

  function onPointerMove(e) {
    // ⚠️ **拖动课表期间完全不理指针移动**（2026-11）。
    //
    // 窗口跟着鼠标走 → 指针在窗口里的相对位置一直变 → 跟随模式会
    // 把面板一个接一个地打开 / 收起（用户看到「突然出现 → 消失 → 渐渐出现」）。
    // 拖动和看详情是互斥的，拖动时不该有任何面板动作。
    if (DP.dragging) return;
    DP.pointer = { x: e.clientX, y: e.clientY };
    // 没点开过（或已经点掉）→ 悬停不弹。
    //
    // 面板的「打开」只能靠点日期（规格一：触发 = 点表头日期格）；
    // 但是**一旦点开，就进入跟随模式**：淡出（移出课表 / 移到时间列）
    // 不等于关闭，移回来继续跟着出现。
    if (!DP.following) return;
    // ⚠️ **菜单开着时不要跟着指针换列**（2026-11）。
    //
    // 菜单弹在指针位置 → 指针一动就可能落到别的列 → 覆盖层跟着换列 →
    // 用户点「修改…」时改的是**另一条**待办（或者那一列还没数据，显示是空的）。
    // 菜单期间保持当前列不动。
    if (DP.menuOpen) return;
    // ⚠️ **正在输入（添加待办 / 修改待办）时，面板钉在当前列**（2026-11-05 用户反馈）。
    //
    // 用户原话：「点了添加待办 / 正在改某列的待办，鼠标不小心滑到别的列，
    // 原本要输入的那一列就没了 —— 把它固定住，以免鼠标误滑动」。
    //
    // 2026-11-10：**写日记时同样锁列**（用户：「点击了添加日记之后输入的时候
    // 移动到别的列，不跳转，仍留在当前这一列」）—— 条件里加了 `DP.diaryForm`。
    //
    // 换列 = `openPanel(day)` 重建整块内容 → 正在输入的 `<input>` 被销毁，
    // 打了一半的标题 / 时间直接丢。所以输入期间**只认当前那一列**：
    // 指针滑到别的列就当没发生（面板留在原列、内容不动）。
    //
    // 指针滑出卡片时的收起也已经被 `onPointerLeave` 里的
    // `DP.adding / DP.editingTodoKey` 兜住了；提交（回车）或取消（Esc）
    // 之后这两个标记归零，跟随立刻恢复。
    //
    // 注意：**点表头仍然是主动换列**（那是明确意图，会放弃正在输入的内容）——
    // 这条只拦「移动」。
    if (DP.adding || DP.editingTodoKey || DP.diaryForm) {
      DP.hoverDay = DP.day;
      return;
    }
    var day = dayAtPoint(e.clientX, e.clientY);
    DP.hoverDay = day;
    if (day === null) {
      // 移到不在任何列的地方（时间列 / 状态条 / 课表外）→ 淡出。
      // ⚠️ 只是淡出，`following` 保持 —— 移回某一列还会继续出现。
      // ⚠️ 正在「添加待办」交互中（输入框展开 / 系统权限框弹出）**不淡出**：
      // 权限框在屏幕中央弹出，用户去点「允许」必然离开卡片，
      // 这时把面板收走 = 「点一下新增提醒事项面板直接消失」。
      // 权限框流程 / 打字期间面板必须留着，提交或 Esc 后才恢复。
      if (DP.open && !DP.adding && !DP.diaryForm) {
        fadeOutPanel();
      }
      return;
    }
    if (!DP.open) {
      // 跟随模式下收拢过（比如刚刚移出课表又移回来）→ 重新出现
      openPanel(day);
    } else if (DP.day !== day) {
      // 横向移到别的列 → 覆盖层跟着换到新列。
      // ⚠️ **不再调 fadeOutPanel**（旧版淡出）——面板是**同一个元素**，
      // openPanel 会直接 positionPanel 移到新列 + renderPanel 换内容，
      // 两套消失动画（fading/closing）并存的冲突由此消除。
      // 换列一律回到窄态：宽态是「锁在原列」的状态，不该被横向移动改写。
      openPanel(day);
    }
  }

  function onPointerLeave() {
    // ⚠️ **原生菜单开着时，什么都不做**（2026-11）。
    //
    // 菜单弹出的瞬间指针就离开了卡片（菜单在卡片矩形之外）——
    // 这时候把覆盖层收走，用户看到的就是「点删除 / 修改，整个日历闪一下」。
    //
    // ⚠️ 连 `DP.pointer` / `DP.hoverDay` 都不清：
    // 清了的话，菜单关闭后第一次 `onPointerMove` 会拿「空位置」去判断，
    // 可能把覆盖层换到别的列去（用户看到「内容不对」）。
    // 原生在菜单关闭后会把标志清掉，这时才恢复正常跟随。
    if (DP.menuOpen) return;
    // ⚠️ 拖动期间不收（原生那边拖动时会主动收，这里别重复动作）。
    if (DP.dragging) return;
    DP.pointer = null;
    DP.hoverDay = null;
    // ⚠️ 添加待办交互中（输入框展开 / 系统权限框流程）离开卡片**不收起面板**——
    // 鼠标去点权限框的「允许」必然离开卡片，面板不该跟着消失。
    // 用户提交（回车）或 Esc 取消后 `DP.adding` 归 false，恢复正常跟随。
    //
    // ⚠️ **编辑态同理**（2026-11）：右键「修改…」后要去点菜单里的「修改…」，
    // 指针必然离开卡片 —— 面板不能在这时候收走。
    if (DP.open && !DP.adding && !DP.editingTodoKey && !DP.diaryForm) fadeOutPanel();
  }

  // ---- 时钟 / 状态条 ----

  // 上一次定时更新时的日期（`YYYY-M-D`）—— 跨天要重画表头的「今天」蓝点。
  var lastTickerDay = null;

  // 状态条 / 时钟的文字（纯函数）。
  //
  // render() 用它建顶部，网页自己的定时器也用它就地更新 ——
  // 文字逻辑只此一份，避免「重绘」和「定时刷新」算出两套不一样的话。
  function liveTickerTexts(now, ctx) {
    var statusText = '', statusMeta = '', live = false;
    var cur = ctx.cur;
    if (ctx.isAllWeeks) {
      statusText = '全部周次 · 共 ' + ctx.courses.length + ' 门课';
      statusMeta = semesterRangeText(ctx.semStart) + '　·　第 1–' + MAX_WEEK + ' 周全部课程';
    } else if (!ctx.isCurWeek) {
      statusText = '第 ' + ctx.week + ' 周 · 共 ' + ctx.weekCount + ' 门课';
      statusMeta = weekDateText(ctx.week, ctx.semStart) + '　·　本学期第 1–' + MAX_WEEK + ' 周　·　用左右箭头浏览其他周次';
    } else if (ctx.curCourse) {
      live = true;
      var left = toMin(blockEnd(ctx.curBlock)) - cur;
      statusText = '正在上课 · ' + ctx.curCourse.name;
      statusMeta = blockStart(ctx.curBlock) + '–' + blockEnd(ctx.curBlock) + '　·　剩 ' + fmtGap(left) + '　·　' + briefLoc(ctx.curCourse.loc);
    } else if (ctx.nextCourse) {
      var untilStart = toMin(blockStart(ctx.nextBlock)) - cur;
      statusText = '下一节 · ' + ctx.nextCourse.name;
      statusMeta = blockStart(ctx.nextBlock) + ' 开始　·　还有 ' + fmtGap(untilStart) + '　·　' + briefLoc(ctx.nextCourse.loc);
    } else {
      statusText = ctx.todayCount > 0 ? '今日课程已结束' : '今天没有课';
      statusMeta = ctx.todayCount > 0 ? '今天共 ' + ctx.todayCount + ' 门课　·　好好休息' : '自由安排';
    }
    return {
      clockStr: pad(now.getHours()) + ':' + pad(now.getMinutes()),
      dateStr: (now.getMonth() + 1) + '月' + now.getDate() + '日 ' + DAYS[ctx.today - 1],
      statusText: statusText,
      statusMeta: statusMeta,
      live: live
    };
  }

  // 按 render() 的口径现算状态条需要的「今天」上下文。
  // 只算状态条用得上的东西：今天的课、当前节次、下一节、计数。
  function liveContext(now) {
    var courses = S.courses || [];
    var curWeek = (typeof S.currentWeek === 'number' && S.currentWeek >= 1 && S.currentWeek <= MAX_WEEK)
      ? S.currentWeek : null;
    var week = (typeof S.viewWeek === 'number') ? S.viewWeek : null;
    if (week !== null && (week < 1 || week > MAX_WEEK)) week = MAX_WEEK;
    var semStart = parseSemesterStart(S.semesterStart);
    var isAllWeeks = week === null;
    var isCurWeek = !isAllWeeks && curWeek !== null && week === curWeek;
    var jsDay = now.getDay();
    var today = jsDay === 0 ? 7 : jsDay;
    var cur = now.getHours() * 60 + now.getMinutes();
    var runsCurWeek = function (c) {
      return curWeek === null ? true : (c.weeks || []).indexOf(curWeek) >= 0;
    };

    // 同一格多门课：render() 取 courses 里的第一门；覆盖课随后顶掉。
    var map = {};
    courses.forEach(function (c) {
      var k = c.day + '-' + c.block;
      if (!map[k]) map[k] = c;
    });
    var ovMap = {};
    if (!isAllWeeks) {
      (S.overrides || []).forEach(function (o) {
        if ((o.weeks || []).indexOf(week) >= 0) ovMap[o.day + '-' + o.block] = o;
      });
      Object.keys(ovMap).forEach(function (k) {
        var o = ovMap[k];
        map[k] = { name: o.name, loc: o.loc, day: o.day, block: o.block,
                   weeks: o.weeks, isOverride: true };
      });
    }

    var curBlock = -1;
    for (var i = 0; i < 5; i++) {
      if (cur >= toMin(blockStart(i)) && cur <= toMin(blockEnd(i))) { curBlock = i; break; }
    }
    var curCell = curBlock >= 0 ? map[today + '-' + curBlock] : null;
    var curCourse = (curCell && runsCurWeek(curCell)) ? curCell : null;

    var nextCourse = null, nextBlock = -1;
    for (var j = 0; j < 5; j++) {
      if (toMin(blockStart(j)) > cur) {
        var nc = map[today + '-' + j];
        if (nc && runsCurWeek(nc)) { nextCourse = nc; nextBlock = j; break; }
      }
    }

    var todayCount = 0, weekCount = 0;
    courses.forEach(function (c) {
      var k = c.day + '-' + c.block;
      if (ovMap[k]) return;
      if (c.day === today && runsCurWeek(c)) todayCount++;
      if (!isAllWeeks && (c.weeks || []).indexOf(week) >= 0) weekCount++;
    });
    Object.keys(ovMap).forEach(function (k) {
      var o = ovMap[k];
      if (o.day === today && runsCurWeek(o)) todayCount++;
      weekCount++;
    });

    return {
      courses: courses, semStart: semStart, isAllWeeks: isAllWeeks,
      isCurWeek: isCurWeek, week: week, today: today, cur: cur,
      curBlock: curBlock, curCourse: curCourse,
      nextBlock: nextBlock, nextCourse: nextCourse,
      todayCount: todayCount, weekCount: weekCount
    };
  }

  // 就地刷新顶部时钟 / 日期 / 状态条 —— **不重建 DOM**。
  //
  // ⚠️ **为什么需要**（2026-11 修「课表上的时间停在半小时前」）：
  // 时钟 / 状态条原来只在 render() 里算。原生每分钟推一次状态时，
  // 数据本身没变 → `tableStateKey` 判成「没变」→ 走轻量路径，顶部不重画；
  // 于是时间冻在**上一次真正重绘**的时候（翻周 / 改设置才跳一下）。
  // 现在网页自己每 10 秒把文字就地换一遍，和原生推不推无关。
  function updateLiveTexts() {
    if (!S) return;
    var now = new Date();
    // 跨天：表头的「今天」蓝点、日期列都要重画 —— 交给整树 render()。
    var dayKey = now.getFullYear() + '-' + now.getMonth() + '-' + now.getDate();
    if (lastTickerDay !== null && lastTickerDay !== dayKey) {
      lastTickerDay = dayKey;
      render();
      return;
    }
    lastTickerDay = dayKey;

    var tick = liveTickerTexts(now, liveContext(now));
    var clockEl = document.querySelector('.clock .tnum');
    var dateEl = document.querySelector('.clock .tdate');
    var statusEl = document.querySelector('.status');
    if (clockEl) clockEl.textContent = tick.clockStr;
    if (dateEl) dateEl.textContent = tick.dateStr;
    if (statusEl) {
      statusEl.classList.toggle('live', tick.live);
      var pulse = statusEl.querySelector('.pulse');
      if (pulse) pulse.classList.toggle('idle', !tick.live);
      var stxt = statusEl.querySelector('.stxt');
      var smeta = statusEl.querySelector('.smeta');
      if (stxt) stxt.textContent = tick.statusText;
      if (smeta) smeta.textContent = tick.statusMeta;
    }
  }

  // ---- 渲染 ----
  function render() {
    // ⚠️ **必须先判空再解引用**（2026-11-09 修「时钟不走」）：
    // 启动时脚本尾部那次 render() 跑在状态到达之前，`S` 还是 undefined；
    // 旧写法先去读 `S.viewWeek` 直接抛 TypeError → 把后面「装时钟定时器」
    // 那段一起中断 → 时钟只在下次推状态时才更新（用户：「时间一直对不上」）。
    window.__ttRenderCount = (window.__ttRenderCount || 0) + 1;
    if (!S) return;
    window.__ttRenderWeek = (typeof S.viewWeek === 'number') ? S.viewWeek : null;
    var root = document.getElementById('root');
    if (!root) return;

    var courses = S.courses || [];
    // 作息时间：以 native 推入的为准（用户可在设置里自定义）。
    // 只有节数对得上才替换，避免坏数据把时间列画错。
    if (S.periods && S.periods.length === PERIODS.length) {
      var ps = [];
      for (var pi = 0; pi < S.periods.length; pi++) {
        var p = S.periods[pi] || {};
        ps.push({ s: p.s || PERIODS[pi].s, e: p.e || PERIODS[pi].e });
      }
      PERIODS = ps;
    }
    // 学期总周数：来自 native（semester.json / effectiveMaxWeek）
    MAX_WEEK = (typeof S.maxWeek === 'number' && S.maxWeek >= 1 && S.maxWeek <= 30)
      ? S.maxWeek : 16;
    var curWeek = (typeof S.currentWeek === 'number' && S.currentWeek >= 1 && S.currentWeek <= MAX_WEEK)
      ? S.currentWeek : null;
    var week = (typeof S.viewWeek === 'number') ? S.viewWeek : null;
    // 夹回合法范围。native 那边一般已经夹过了，但网页自己也守一道：
    // 换了一份周数更少的课表时，旧周次（比如第 18 周）可能还在传输途中，
    // 界面上会冒出「第 18 周」而课表只有 16 周。
    if (week !== null && (week < 1 || week > MAX_WEEK)) week = MAX_WEEK;

    var semStart = parseSemesterStart(S.semesterStart);
    var isAllWeeks = week === null;
    var isCurWeek = !isAllWeeks && curWeek !== null && week === curWeek;

    var now = new Date();
    var jsDay = now.getDay();
    var today = jsDay === 0 ? 7 : jsDay;
    var cur = now.getHours() * 60 + now.getMinutes();

    // 同一格可能有多门课（冲突）。先按格收集，再决定显示哪一门 + 标记冲突。
    var slots = {};
    courses.forEach(function (c) {
      var k = c.day + '-' + c.block;
      (slots[k] = slots[k] || []).push(c);
    });
    var map = {};
    var conflictSlots = {};
    Object.keys(slots).forEach(function (k) {
      var list = slots[k];
      // 显示的那一门：优先当前正在上的；否则按周次交集最小的排前面，取第一个
      map[k] = list[0];
      // 冲突判定：不同 courseID、同一格、weeks 有交集
      var byID = {};
      list.forEach(function (c) { byID[c.courseID || ('#' + c.name)] = c; });
      var uniq = Object.keys(byID).map(function (k2) { return byID[k2]; });
      var hit = false;
      for (var a = 0; a < uniq.length && !hit; a++) {
        for (var b = a + 1; b < uniq.length && !hit; b++) {
          var wa = uniq[a].weeks || [], wb = uniq[b].weeks || [];
          for (var w = 0; w < wa.length; w++) {
            if (wb.indexOf(wa[w]) >= 0) { hit = true; break; }
          }
        }
      }
      if (hit) conflictSlots[k] = uniq;
    });

    var runsThisWeek = function (c) { return isAllWeeks ? true : (c.weeks || []).indexOf(week) >= 0; };
    var runsCurWeek = function (c) { return curWeek === null ? true : (c.weeks || []).indexOf(curWeek) >= 0; };

    // ---- 单周临时覆盖 ----
    //
    // 覆盖 = 某个格子在**某几周**里归覆盖课。
    // 「全部周次」视图**忽略**覆盖 —— 那边只显示原始课表。
    var ovMap = {};
    if (!isAllWeeks) {
      (S.overrides || []).forEach(function (o) {
        if ((o.weeks || []).indexOf(week) >= 0) ovMap[o.day + '-' + o.block] = o;
      });
    }
    // 覆盖格：这一周只显示覆盖课 —— 原来的课被遮住
    Object.keys(ovMap).forEach(function (k) {
      var o = ovMap[k];
      map[k] = {
        courseID: o.courseID, name: o.name, code: o.code, teacher: o.teacher,
        loc: o.loc, day: o.day, block: o.block, weeks: o.weeks,
        weeksLabel: o.weeksLabel, isOverride: true,
        // 覆盖课也有自己的颜色（原生解析好推过来的）
        color: o.color
      };
      // 这一格只显示一门课 → 不算冲突
      delete conflictSlots[k];
    });

    var curBlock = -1;
    for (var i = 0; i < 5; i++) {
      if (cur >= toMin(blockStart(i)) && cur <= toMin(blockEnd(i))) { curBlock = i; break; }
    }
    var curCell = curBlock >= 0 ? map[today + '-' + curBlock] : null;
    var curCourse = (curCell && runsCurWeek(curCell)) ? curCell : null;

    var nextCourse = null, nextBlock = -1;
    for (var j = 0; j < 5; j++) {
      if (toMin(blockStart(j)) > cur) {
        var nc = map[today + '-' + j];
        if (nc && runsCurWeek(nc)) { nextCourse = nc; nextBlock = j; break; }
      }
    }

    // 统计：被覆盖的格子算**覆盖课**，原课不重复算。
    var todayCount = 0, weekCount = 0;
    courses.forEach(function (c) {
      var k = c.day + '-' + c.block;
      if (ovMap[k]) return;                      // 原课被覆盖 → 由覆盖课顶上
      if (c.day === today && runsCurWeek(c)) todayCount++;
      if (!isAllWeeks && (c.weeks || []).indexOf(week) >= 0) weekCount++;
    });
    Object.keys(ovMap).forEach(function (k) {
      var o = ovMap[k];
      if (o.day === today && runsCurWeek(o)) todayCount++;
      weekCount++;
    });

    // 顶部文字走和定时刷新同一份逻辑，避免两处算出不一样的话。
    var tick = liveTickerTexts(now, {
      courses: courses, semStart: semStart, isAllWeeks: isAllWeeks,
      isCurWeek: isCurWeek, week: week, today: today, cur: cur,
      curBlock: curBlock, curCourse: curCourse,
      nextBlock: nextBlock, nextCourse: nextCourse,
      todayCount: todayCount, weekCount: weekCount
    });
    var statusText = tick.statusText, statusMeta = tick.statusMeta, live = tick.live;
    var clockStr = tick.clockStr, dateStr = tick.dateStr;
    lastTickerDay = now.getFullYear() + '-' + now.getMonth() + '-' + now.getDate();

    var rows = [];
    var baseWeek = isAllWeeks ? (curWeek || 1) : week;
    var baseMonday = weekMonday(baseWeek, semStart);
    var baseMonth = baseMonday.getMonth();
    var todayMidnight = new Date(now.getFullYear(), now.getMonth(), now.getDate());

    rows.push(h('div', { class: 'hcell hcorner', style: { gridRow: 1, gridColumn: 1 } },
      h('span', { class: 'mon', text: String(baseMonth + 1) }),
      h('span', { class: 'monu', text: '月' })));

    // 当前选中的那一列（打开 / 收起动画期间都算）。
    //
    // ⚠️ **建表头时就把 `.sel` 写进初始 class**（2026-11 修「表头一暗一亮」）。
    //
    // 原来是先建好格子、插进文档，再由 `syncHeaderSel()` 补 `.sel` ——
    // 新节点的初始样是暗色（42%），补上 `.sel` 是一次样式变化，
    // 会**重新播一遍 200ms 颜色过渡**（暗 → 亮）。
    // 只要有一次 `render()`（原生推送导致），用户就看到表头「闪一下」。
    // 带着 `.sel` 一起建出来的节点从第一帧就是白色，不会过渡。
    var headerSelDay = DP.open ? DP.day : (DP.closing ? DP.closingDay : null);

    for (var d = 1; d <= 7; d++) {
      var dt = weekDayDate(baseWeek, semStart, d);
      var dayNum = dt.getMonth() !== baseMonth
        ? (dt.getMonth() + 1) + '.' + dt.getDate()
        : '' + dt.getDate();
      var isTodayCol = dt.getTime() === todayMidnight.getTime();
      // 表头三段式：左槽（红点=有待办 / 橙点=有日程）· 中间（周几 + 几号）· 右（蓝点=今天）
      // 有点才渲染槽里的点，没点就不留空位（中间段 flex:1 居中，左右宽度差由它吸收）。
      var flags = dayFlagsOf(d);
      // ⚠️ **「全部周次」模式下不画红点 / 橙点**（2026-11）。
      //
      // 全部周次 = 所有教学周的课程叠在一起，「周三」指哪一天没有定义。
      // 这时画一个「周三有待办」的红点，指向的只是**当前那一周**的周三，
      // 和用户看到的「所有周」对不上号。
      //
      // 原生侧也会把 `dayFlags` 清空，这里再挡一道 ——
      // 万一有别的地方推了带标记的状态过来，也不会显示。
      var allWeeks = isAllWeeksMode();
      var hasTodo = !allWeeks && !!(flags && flags.todo);
      var hasEvent = !allWeeks && !!(flags && flags.event);
      var hasDiary = !allWeeks && !!(flags && flags.diary);
      // ⚠️ **红点挪到「周几」文字的左边**（2026-11 改）。
      //
      // 以前红点 / 橙点是绝对定位在**格子最左缘**的（`.hslot`），
      // 而蓝点（今天）在 `.hdrow` 里 = [周几][蓝点]，在「周一」二字**右边**。
      // 于是红点和蓝点**不在同一水平线**，离中轴的距离也差得远
      // （红点 57pt，蓝点 ~10pt）—— 看着不对称。
      //
      // 现在中间段变成「🔴 周一 🔵」——
      // 红点和蓝点**同一水平线**、**分居「周几」文字两侧**，真正对称。
      //
      // ⚠️ 橙点（有日程）**仍在红点下方** —— 它是「第二个」标记，
      // 竖着排才放得下（表头格只有 38pt 高）。
      rows.push(h('div', {
        class: 'hcell' + (isTodayCol ? ' today' : '') + ' pick'
          + (headerSelDay === d ? ' sel' : ''),
        'data-day': d,
        style: { gridRow: 1, gridColumn: d + 1 },
        title: DAYS[d - 1] + ' ' + dayNum,
        onclick: (function (dd) { return function () { onHeaderPick(dd); }; })(d)
      },
        h('span', { class: 'hmid' },
          h('span', { class: 'hdrow' },
            // ⚠️ **红点 / 蓝点永远占位**（2026-11 修「表头闪一下」+「周几没对齐」）。
            //
            // 以前没点的时候直接不渲染 → 加 / 删待办时节点被插进来 / 摘出去，
            // 「周一」两个字跟着左右跳一下，看起来就是表头闪了一下。
            // 现在点一直在（没有时加 `.off` = 不可见但**占位**），
            // 只是切换可见性，文字位置永远不动。
            //
            // ⚠️ **蓝点（今天）以前只有今天那一列才渲染** —— 于是今天这列
            // 「周几」被挤得偏左，和其他列、和下面的号数都对不齐（2026-11 修）。
            // 现在和红点一样：每列都渲染，不是今天就 `.off` 占位，
            // 左右各一个点，文字永远在正中。
            h('span', { class: 'dot todo' + (hasTodo ? '' : ' off') }),
            // 周几两个字**固定宽度**：下面号数那一行也是同样的固定宽度，
            // 这样上下两排的左边点（红点 / 绿点）才在**同一条竖线**上。
            h('span', { class: 'hdaytext', text: DAYS[d - 1] }),
            h('span', { class: 'dot' + (isTodayCol ? '' : ' off') })),
          // 号数这一行：**绿点（日记）+ 号数 + 占位点**。
          // 左右各留一个 4px 的点位（和上面「红点 / 蓝点」同样的 gap:3），
          // 所以号数永远在正中，绿点出现 / 消失都**不会把数字挤偏**。
          h('span', { class: 'hnumrow' },
            h('span', { class: 'dot diary' + (hasDiary ? '' : ' off') }),
            h('span', { class: 'hnum', text: dayNum }),
            h('span', { class: 'dot off' })),
          h('span', { class: 'dot event' + (hasEvent ? '' : ' off') }))));
    }

    for (var p = 0; p < PERIODS.length; p++) {
      rows.push(h('div', { class: 'tcell', style: { gridRow: p + 2, gridColumn: 1 } },
        h('span', { class: 'tn', text: String(p + 1) }),
        h('span', { class: 'ts', text: PERIODS[p].s }),
        h('span', { class: 'te', text: PERIODS[p].e })));

      var bi = Math.floor(p / 2);
      var isFirstOfBlock = p % 2 === 0;

      for (var dd = 1; dd <= 7; dd++) {
        var c = map[dd + '-' + bi];
        if (!c) {
          rows.push(h('div', {
            class: 'cell empty',
            style: { gridRow: p + 2, gridColumn: dd + 1 },
            'data-day': dd,
            'data-block': bi
          }));
          continue;
        }
        if (!isFirstOfBlock) continue;

        var isNow = !!(curCourse && isCurWeek && dd === today && bi === curBlock);
        var pal = paletteOf(c);
        var active = runsThisWeek(c);
        rows.push(h('div', {
          class: 'cell course' + (active ? '' : ' off'),
          'data-day': dd,
          'data-block': bi,
          'data-cid': c.courseID || '',
          'data-name': c.name || '',
          style: {
            gridRow: (p + 2) + ' / span 2',
            gridColumn: dd + 1,
            // 非本周的格子单独给一套更淡的底色/描边 ——
            // 以前是靠整格 opacity 0.26 实现的，那会把字形一起压薄，
            // 看着像换了字体。现在改成「底色淡 + 文字颜色淡」，字形本身不打折。
            borderColor: isNow ? pal[0] : (active ? 'rgba(255,255,255,0.08)' : 'rgba(255,255,255,0.04)'),
            background: isNow ? pal[1] + '0.24)' : (active ? pal[1] + '0.095)' : pal[1] + '0.04)'),
            boxShadow: isNow ? '0 0 0 1px ' + pal[1] + '0.55), 0 10px 30px ' + pal[1] + '0.32)' : 'none'
          },
          onclick: (function (cc) { return function () { sel = cc; render(); }; })(c)
        },
          h('div', { class: 'cname' },
            h('span', { class: 'bar', style: { background: pal[0] } }),
            h('span', { class: 'ntxt', text: c.name })),
          h('div', { class: 'cloc', text: briefLoc(c.loc) }),
          h('div', { class: 'cwk', text: briefTeacher(c.teacher) + ' · ' + c.weeksLabel + ' 周' }),
          conflictSlots[dd + '-' + bi]
            ? h('div', { class: 'cconf', title: '冲突：' + conflictSlots[dd + '-' + bi].map(function (x) { return x.name; }).join(' / '), text: '⚠' })
            : null,
          c.isOverride
            ? h('div', { class: 'covr', title: '临时覆盖：这一格在第 ' + (c.weeksLabel || '') + ' 周被覆盖', text: '覆' })
            : null,
          !active ? h('div', { class: 'cnot', text: '非本周' }) : null));
      }
    }

    var selPal = sel ? paletteOf(sel) : null;

    // 网格单独建：覆盖层要挂在它里面（position: relative），
    // 双击表头也要在这里接。
    var gridEl = h('div', { class: 'grid' }, rows);
    // 折叠时收的是这个容器的**高度**：表头留在顶部，下面的时间段被裁掉。
    // 只裁剪、不动网格内部几何 —— 表头 / 日期列的坐标一个都不变。
    var gridWrap = h('div', { class: 'gridwrap' }, gridEl);
    // ⚠️ **双击撑开已删**（2026-11）—— 不再监听 dblclick。
    //
    // 以前双击表头 / 双击覆盖层条目区会把面板撑开成宽态。
    // 那个形态盖住旁边的列、底边是硬边，观感不好，而且用处不大
    // （窄态现在能滚，内容一样能看全）。
    DP.grid = gridEl;

    var card = h('div', { class: 'ttcard card', style: {
      '--tt-min-opacity': 1,
      '--tt-max-opacity': 1
    } },
      h('div', { class: 'top' },
        h('div', { class: 'brand' },
          h('div', { class: 'ttl' },
            h('span', { class: 'ttltxt', text: S.title || '本周课表' }),
            // 图钉画在网页里（2026-11）：和标题同一个 DOM / 同一个缩放，
            // 缩放拖动时不会再和左边标题「各走各的」。点击由原生热区接管，
            // 这里的 onclick 是兜底（比如固定态下点击直接落到网页上）。
            h('img', { class: 'ttlpin' + (pinPinned ? ' on' : ''),
                       alt: '',
                       src: pinPinned ? PIN_IMG.solid : PIN_IMG.hollow,
                       title: pinPinned ? '解锁课表' : '固定课表',
                       onclick: function (e) {
                         if (e && e.stopPropagation) e.stopPropagation();
                         post('pinToggle', { pinned: !pinPinned });
                       } })),
          h('div', { class: 'sub', text: S.subtitle || '' })),

        h('div', { class: 'wkgroup' },
          h('div', {
            class: 'arrow' + (!isAllWeeks && week <= 1 ? ' dis' : ''),
            title: '上一周', text: '◀',
            onclick: function () { post('week', -1); }
          }),
          h('div', { class: 'wkstack' },
            h('div', {
              class: 'wkchip' + (isCurWeek ? ' now' : ''),
              title: '点击切换「全部周次」',
              text: isAllWeeks ? '全部周次' : (isCurWeek ? '本周' : '第 ' + week + ' 周'),
              onclick: function () { post('toggleAllWeeks'); }
            }),
            h('div', {
              class: 'wkdate',
              text: isAllWeeks ? semesterRangeText(semStart) : weekDateText(week, semStart)
            })),
          h('div', {
            class: 'arrow' + (!isAllWeeks && week >= MAX_WEEK ? ' dis' : ''),
            title: '下一周', text: '▶',
            onclick: function () { post('week', 1); }
          }),
          h('div', {
            class: 'nowbtn' + (isAllWeeks || curWeek === null ? ' ghost' : ''),
            text: '回到本周',
            onclick: function () { if (!isAllWeeks && curWeek !== null) post('weekCurrent'); }
          })),

        h('div', { class: 'clock' },
          h('div', null,
            h('div', { class: 'tnum', text: clockStr }),
            h('div', { class: 'tdate', text: dateStr })),
          h('div', {
            class: 'setbtn', title: '课表设置',
            onclick: function () { post('openSettings'); }
          }, gearIcon()))),

      h('div', { class: 'status' + (live ? ' live' : '') },
        h('div', { class: 'pulse' + (live ? '' : ' idle') }),
        h('div', { class: 'stxt', text: statusText }),
        h('div', { class: 'smeta', text: statusMeta }),
        // 折叠按钮：状态条最右侧（用户确认的位置）。一个 18pt 的小圆角块，
        // 展开时显示「▾」，收起后显示「▴」。
        h('div', {
          class: 'collapsebtn' + (collapseProgress > 0.5 ? ' collapsed' : ''),
          title: collapseProgress > 0.5 ? '展开课表' : '收起课表',
          onclick: function () { post('toggleCollapse'); }
        }, h('span', { class: 'collapseico' }))),

      gridWrap,

      sel ? h('div', { class: 'ovl', onclick: function () { sel = null; render(); } },
        h('div', { class: 'sheet', onclick: function (e) { e.stopPropagation(); } },
          h('div', { class: 'sheet-top' },
            h('div', { class: 'sheet-dot', style: { background: selPal[0] } }),
            h('div', null,
              h('div', { class: 'sheet-name', text: sel.name }),
              h('div', { class: 'sheet-code', text: '课程代码 ' + (sel.code || '—') })),
            h('div', { class: 'close', text: '✕', onclick: function () { sel = null; render(); } })),
          h('div', { class: 'row' },
            h('span', { class: 'k', text: '上课时间' }),
            h('span', { class: 'v', text: DAYS[sel.day - 1] + '　第 ' + (sel.block * 2 + 1) + '–' + (sel.block * 2 + 2) + ' 节　' + blockStart(sel.block) + '–' + blockEnd(sel.block) })),
          h('div', { class: 'row' },
            h('span', { class: 'k', text: '任课教师' }),
            h('span', { class: 'v', text: sel.teacher })),
          h('div', { class: 'row' },
            h('span', { class: 'k', text: '上课地点' }),
            h('span', { class: 'v', text: sel.loc })),
          h('div', { class: 'row' },
            h('span', { class: 'k', text: '上课周次' }),
            h('span', { class: 'v', text: '第 ' + sel.weeksLabel + ' 周' })))) : null);

    // ⚠️ **覆盖层元素必须保住** ——
    // `root.innerHTML = ''` 会把旧卡片连同 `.daypanel` 一起删掉。
    // 以前直接重建一份新的 → **入场动画重播** → 用户看到面板闪一下。
    //
    // 现在把元素「摘下来」留着（JS 引用还在），重画完再挂回**新的** grid，
    // 于是 DOM 结构变了但**面板本身是同一个元素**，动画状态不重置。
    //
    // 收拢动画中（`.closing`）也必须保住 ——
    // 它们的收尾定时器还在跑，元素被删掉就收不了尾了。
    var keepPanel = DP.el;
    var wasShow = keepPanel ? keepPanel.classList.contains('show') : false;
    var wasClosing = keepPanel ? keepPanel.classList.contains('closing') : false;
    // ⚠️ **必须在 `root.innerHTML = ''` 之前**采样 ——
    // 那一刻入场动画可能正播到一半（原生在点开后立刻推状态）。
    // 元素一旦被摘掉，transition 就被取消、clip-path 回到终态，
    // 再想「接着播」就没进度可依了。
    var entrance = capturePanelEntrance();

    // ⚠️ **滚动位置也要在这里采样** ——
    //
    // `root.innerHTML = ''` 会把 `.dpbody` 一起删掉，滚动位置随之归零。
    // 下面 `renderPanel()` 里的 `keepScroll` 是从**已经归零的** body 上读的
    // → 读到 0 → 还原成 0 → 用户正往下看时被弹回顶部
    // （表现为「面板自己跳了一下」）。
    //
    // 所以这里**先记下**，重画完再还回去。
    var keepPanelScroll = DP.body ? DP.body.scrollTop : 0;

    // ⚠️⚠️ **输入框必须先「搬」出去**（2026-11 修「打不上字」）。
    //
    // 现象：点开「＋ 添加待办」后打字，**经常打不上**（有时候要重试）。
    //
    // 根因（实测）：
    //   · `root.innerHTML = ''` 会把**整棵 DOM** 拔起，
    //     输入框当场**脱离文档** → 焦点掉到 `<body>`；
    //   · ⚠️ **blur 事件根本不触发**（实测 blur 记录 = []），
    //     所以网页侧的 `onblur` → `post('textInputBlur')` → 原生
    //     `resignKey()` 这条链**根本没走** —— 原生那边不是原因；
    //   · 之后即使 `focus()` 回去，WKWebView **要等下一次绘制**才让它生效
    //     （实测 ~190ms）→ 这段时间里按的键**全丢**
    //     （实测：连续打 11 个字，丢 11 个）。
    //
    // 而且「不在文档里的元素**根本无法获得焦点**」是 DOM 硬规则
    // （实测：detach 之后手动 `focus()` 也无效）——
    // 所以「先 detach 再挂回」这条路走不通。
    //
    // 修法：**输入框有焦点时，根本不重建面板内容**。
    // 待办列表晚一点刷新没关系，打字不能丢。
    // ⚠️⚠️ **输入框有焦点时，整个 render 都别做**（2026-11 修「打不上字」）。
    //
    // 现象：点开「＋ 添加待办」后打字，**经常打不上**（有时候要重试）。
    //
    // 根因（实测）：
    //   · `root.innerHTML = ''` 把**整棵 DOM** 拔起，
    //     输入框当场**脱离文档** → 焦点掉到 `<body>`；
    //   · ⚠️ **blur 事件根本不触发**（实测 blur 记录 = []），
    //     所以原生那条 `resignKey` 的链**根本没走** —— 不是它的锅；
    //   · 之后即使 `focus()` 回去，WKWebView **要等下一次绘制**才让它生效
    //     （实测 ~190ms）→ 这段时间按的键**全丢**
    //     （实测：连续打 11 个字，丢 11 个）。
    //
    // 而且「不在文档里的元素**根本无法获得焦点**」是 DOM 硬规则
    // （实测：detach 之后手动 `focus()` 也无效）——
    // 所以「先 detach 再挂回」这条路走不通。
    //
    // 修法：**输入框有焦点时，什么都别重建**。
    // 待办列表 / 时钟晚一点刷新没关系，打字不能丢。
    //
    // ⚠️ 必须是**在 `root.innerHTML = ''` 之前**判断 ——
    // 那一下就已经把输入框拆了，那时候再判断就晚了。
    if (DP.input && DP.input.parentNode &&
        document.activeElement === DP.input) {
      // 只把表头的选中态补上（它在 render 里重建，这一步不影响输入框）。
      syncHeaderSel();
      return;
    }

    root.innerHTML = '';
    root.appendChild(card);
    // 新 DOM 是「展开」模板 → 按当前折叠进度重新套一遍
    // （否则折叠态下原生一推状态，卡片会先弹开一下再收回去）。
    applyCollapse();

    // 覆盖层跟着重绘走：重画完把它挂回新 grid 并定位，
    // 否则原生一推状态（翻周 / 改设置）覆盖层就没了。
    if (DP.open && DP.day !== null) {
      // ⚠️ **不要**在这里把 DP.el / DP.body / DP.fade 置空 ——
      // 置空就等于「丢掉旧元素、重建新的」，动画又会重播。
      buildPanel();
      if (DP.el) {
        positionPanel();
        renderPanel();
        applyNarrowLimit();
        // ⚠️ **把滚动位置还回去** ——
        //
        // `renderPanel()` 里已经还原过一次（从**旧的** body 读），
        // 但那次的 body 已经被 `innerHTML = ''` 换掉了 → 读到的是 0。
        // 这里用**采样时**记下的值还原，才是真的保住了用户的位置。
        if (keepPanelScroll > 0 && DP.body) {
          DP.body.scrollTop = keepPanelScroll;
        }
        // ⚠️ **不要重新 add('show')** ——
        // 面板本来就开着的话，`show` 一直在身上（元素被复用）。
        // 重新 add 不会重播动画，但**重新 add 之前如果摘过**就会重播。
        // 这里只在「本来就没 show」时补上（例如收拢后又被原生推醒）。
        if (!wasShow && !wasClosing) {
          DP.el.classList.add('show');
          DP.openedAt = nowMs();
        }
        layoutFade();
        // 入场动画被这次重绘打断过 → 从记下的进度接着播剩余时长。
        resumePanelEntrance(entrance);
        // ⚠️ **表头是这次 render 新造的 DOM**，`.sel` 不会自己回来。
        //
        // 原生每次 push 都会走 render()，表头格全部重建 —— 如果不在这里
        // 重新打一次选中态，点开覆盖层后的**第一次**状态推送就会把
        // 表头的蓝色选中底 / 顶部亮线抹掉（用户看到的「点第一下之后
        // 蓝色边框就没了」，指的就是这个选中态）。
        syncHeaderSel();
      }
    } else {
      // 面板不在了（收拢收尾 / 关闭收尾）→ 元素可以丢。
      // 但**收拢动画还在跑**的话不能丢，收尾定时器还要用它 ——
      // 而且这次 render 已经把它从旧卡片里摘下来了，必须挂回新 grid，
      // 否则它就在「看不见的地方」把动画播完。
      if (wasClosing && DP.el) {
        buildPanel();
      } else {
        DP.el = null;
        DP.body = null;
        DP.fade = null;
      }
      syncHeaderSel();
    }
    // 重建 DOM 后把折叠高度补回去（否则原生一推状态，卡片就自己展开）。
    applyCollapse();
  }

  // ---- 折叠 / 展开 ----
  //
  // 折叠 = 只留顶栏 + 状态条 + 表头（网格容器裁到表头高度）。
  // 进度由原生每动画帧调 `window.ttSetCollapse(p)` 推过来，
  // 原生那边同时改毛玻璃 / 点击穿透 / 悬停 —— 两边同一帧生效。
  var collapseProgress = 0;

  function applyCollapse() {
    var card = document.querySelector('.ttcard.card');
    var wrap = card ? card.querySelector('.gridwrap') : null;
    var grid = wrap ? wrap.firstElementChild : null;
    if (!card || !wrap || !grid) return;
    // 网格总高（版式 px，不受 pageZoom / transform 影响）—— 缓存在元素上，
    // 每帧只改高度，不逐帧读布局。
    if (!grid.__ttFullH) grid.__ttFullH = grid.offsetHeight;
    var full = grid.__ttFullH;
    var head = 38;                     // 表头行高（见 .grid 的 grid-template-rows）
    var p = collapseProgress;
    wrap.style.height = (head + (full - head) * (1 - p)) + 'px';
    card.style.setProperty('--tt-collapse', String(p));
    // 折叠态：卡片要让日期覆盖层伸出来（CSS 里 `.card.collapsed`）。
    var wasCollapsed = card.classList.contains('collapsed');
    card.classList.toggle('collapsed', p > 0.5);
    // 跨过一半 → 覆盖层的宿主在 `.grid` / `.card` 之间换一次，并重新定位。
    if (wasCollapsed !== (p > 0.5) && DP.el) {
      var host = panelHost();
      if (host && DP.el.parentNode !== host) {
        host.appendChild(DP.el);
      }
      positionPanel();
    }
    var btn = card.querySelector('.collapsebtn');
    if (btn) {
      btn.classList.toggle('collapsed', p > 0.5);
      btn.title = p > 0.5 ? '展开课表' : '收起课表';
      // 箭头方向由 CSS 旋转（.collapsebtn.collapsed .collapseico）。
    }
  }

  window.ttSetCollapse = function (p) {
    collapseProgress = Math.max(0, Math.min(1, Number(p) || 0));
    applyCollapse();
  };

  // 原生推入状态
  window.ttUpdate = function (json) {
    window.__ttUpdateCalls = (window.__ttUpdateCalls || 0) + 1;
    var next = json;
    if (typeof next === 'string') {
      try { next = JSON.parse(next); } catch (e) {
        // 解析失败：记下来，别让整页静默空白
        window.__ttParseError = String((e && e.message) || e);
        return;
      }
    }
    if (!next) return;
    window.__ttUpdateWeeks = (window.__ttUpdateWeeks || []);
    window.__ttUpdateWeeks.push(next.viewWeek);
    if (window.__ttUpdateWeeks.length > 8) window.__ttUpdateWeeks.shift();

    // ⚠️ 先判断「课表本身有没有变」——只有覆盖层 / 小圆点变化时
    // 不重建整张表（否则完成待办时表头会闪几下）。
    var tableChanged = tableStateKey(S) !== tableStateKey(next);
    try {
    // 选中的课程在状态切换后可能已经不存在了
    if (sel) {
      var still = false;
      (next.courses || []).forEach(function (c) {
        if (c.day === sel.day && c.block === sel.block) still = true;
      });
      if (!still) sel = null;
    }
    S = next;
    // ⚠️ **换周 → 按周隔离的缓存 / 请求标记 / 已加载记录一起作废**（2026-11 修）。
    // 不在这里做的话，下一步的 openPanel 可能还拿着上一周的状态。
    resetWeekCaches(viewWeekKey());
    // ⚠️ **系统数据变了 → 作废按天缓存**（2026-11 修「系统里勾完，红点没了条目还在」）。
    //
    // 场景：用户在系统「提醒事项」里勾掉一条 → 原生重算红点（红点消失），
    // 但如果那一刻面板是**关着的**（原生 `currentDay == nil`），
    // 就没有可推的 `dayPanel`；网页这边的 `DP.cache` / `DP.loaded`
    // 还留着旧列表 → 鼠标移回那一列时直接画缓存，已完成的条目还在。
    //
    // 原生每次「系统数据变了」都会把 `dayPanelRevision` 加一，
    // 这里看到变了就清空缓存；面板开着 / 跟随中时立刻重新要这一天。
    // 「取消添加 / 编辑」令牌（原生按 Esc 时加一）：号码变了就取消。
    //
    // ⚠️ 为什么不靠 DOM 的 keydown：窗口刚变 key 时第一下 Esc 会被系统吃掉，
    // 网页根本收不到。状态推送是每轮都在走的通道，这里才靠得住。
    if (typeof next.cancelCompose === 'number' && next.cancelCompose !== DP.cancelCompose) {
      DP.cancelCompose = next.cancelCompose;
      if (window.ttCancelEditing) window.ttCancelEditing();
    }
    // 固定状态随状态快照一起来（重建 DOM 后图钉不会回到默认态）。
    if (typeof next.pinned === 'boolean' && next.pinned !== pinPinned) {
      pinPinned = next.pinned;
      applyPinVisual();
    }
    var rev = next.dayPanelRevision;
    if (typeof rev === 'number' && rev !== DP.revision) {
      DP.revision = rev;
      // ⚠️ **保留当前打开那天的完整缓存**（2026-11 修「保存后闪一下」）。
      //
      // 触发版本号的不只有外部改动，**我们自己写回待办也会**收到
      // `EKEventStoreChanged`。以前这里无条件清空所有缓存 → 立刻重新要数据，
      // 原生 `open(day:)` 会先推一份 `ready:false` 的中间态 → 网页没有
      // 完整数据可顶 → 渲染成「读取中…」，约 0.5 秒后真数据回来再重画，
      // 整个面板闪一下（用户截图里看到的中间态）。
      //
      // 缓存里已有完整数据时留着它先顶着（stale-while-revalidate）：
      // 新数据回来会覆盖缓存；`loaded` / `requestedDay` 照旧作废并重新请求，
      // 所以面板关着时缓存的旧列表仍会被清掉，不会出现「勾完了条目还在」。
      var openDayCache = (DP.open && DP.day !== null) ? DP.cache[DP.day] : null;
      DP.cache = {};
      if (openDayCache && openDayCache.ready !== false) {
        DP.cache[DP.day] = openDayCache;
      }
      DP.loaded = {};
      DP.requestedDay = null;
      if (DP.open && DP.day !== null) {
        DP.requestedDay = DP.day;
        post('datePanelOpen', { day: DP.day });
      }
    }
    // ⚠️ **缓存原生推来的 dayPanel** ——
    // 原生每次 push 的 dayPanel 只对应**当前那一天**，
    // 换列时对不上 → `panelDataFor()` 返回 null → 整块内容消失。
    // 缓存下来，换列 / 淡出再回来时立刻就能渲染出上一次的数据。
    if (next && next.dayPanel && typeof next.dayPanel === 'object') {
      cacheDayPanel(next.dayPanel);
      var pd = next.dayPanel.day;
      if (typeof pd === 'number') {
        // 原生说 `ready: true` = 待办 / 日程已经查完并合并 —— 这列才算「有完整数据」。
        // 只有「节日」的中间态（ready: false）**不算**，否则真数据被竞态丢掉时
        // 网页会一直显示空列表，也不会再去请求。
        if (next.dayPanel.ready === true) DP.loaded[pd] = true;
        // 请求已经有回包（哪怕是中间态）→ 去重标记作废，
        // 这次没拿到完整数据的话，下次打开还能再要一次。
        if (DP.requestedDay === pd) DP.requestedDay = null;
      }
    }
    // ⚠️ **7 天各自的「今日详情」**（2026-11）——
    // 原生一次推 7 天，这里存下来，换列时按 `day` 取，不会串。
    if (next && next.dayFestivals && typeof next.dayFestivals === 'object') {
      DP.dayFestivals = next.dayFestivals;
    }
    // ⚠️ **原生说「面板该关上了」，网页就跟着关**（2026-11）。
    //
    // 翻周 / 切「全部周次」时，原生会主动关掉覆盖层
    // （旧的那一周的内容不该继续显示）。
    // 网页这边以前**不看** `dayPanelOpen` → 面板一直挂着，
    // 显示的还是**上一周**的农历（用户反馈「翻周之后农历都是一样的」）。
    if (next && Object.prototype.hasOwnProperty.call(next, 'dayPanelOpen')) {
      if (!next.dayPanelOpen && DP.open) {
        closePanel(true);
      }
    }
    // ⚠️ **收拢动画播放期间，跳过整树重建**（2026-11 修）。
    //
    // 现象：点击关闭 / 鼠标离开后，原生立刻推回完整状态 → `tableChanged`
    // 为 true → 走 `render()` 整树重建（`root.innerHTML = ''`）→ 正在播的
    // `.closing` 收起动画（400ms）被「摘下 → 挂回」取消 → 面板瞬间
    // 跳到终态，看不到渐渐收回去的效果。
    //
    // 动画只有 400ms，期间用户改不了课表数据；跳过这次重建最多让
    // 表头小点 / 时钟延迟 400ms 刷新，安全。
    //
    // ⚠️ 现在消失动画只有 `.closing` 一种（fading 淡出已删除），
    // 所以只查 `DP.closing`。
    var panelAnimating = DP.closing;
    if (tableChanged && !panelAnimating) {
      render();
    } else {
      // 轻量路径：表头小点就地更新 + 覆盖层内容更新。
      applyHeaderFlags();
      if (DP.open && DP.day !== null) {
        renderPanel();
        applyNarrowLimit();
        positionPanel();
      }
    }
    } catch (e) {
      window.__ttRenderError = String((e && e.stack) || (e && e.message) || e);
    }
  };

  // 供原生侧查询当前是否有详情面板展开
  window.ttHasSelection = function () { return sel !== null; };

  // 供原生侧做命中测试（A 模式：屏幕上贴的就是这份网页，
  // 命中必须以网页 DOM 为准，不能用原生另算一套几何）。
  window.ttHitTest = function (x, y) {
    return hitPayload(x, y);
  };

  window.ttCloseSelection = function () { if (sel) { sel = null; render(); } };

  // 右键：阻止 WKWebView 默认菜单，把命中的格子回传原生。
  //
  // 只有 B 模式（网页直接上屏）会走到这里 —— 鼠标事件直接落在网页上。
  // A 模式（贴的是静态快照）由原生自己做命中测试，见 TimetableCardView.slotHit。
  document.addEventListener('contextmenu', function (e) {
    e.preventDefault();
    // **覆盖层里的待办条目**：右键只弹菜单（修改… / 删除 / 取消），
    // **不再直接删除**。菜单由原生 NSMenu 弹（面板会滚动、有裁剪和渐隐，
    // 网页里画的菜单容易被裁掉）。
    //
    // 必须在这里（捕获阶段）拦下来 —— 不拦的话事件会走到下面的
    // 「课程格子右键」那条路，弹出来的是课程编辑菜单，语义完全不对。
    //
    // ⚠️ **卡片化之后**：待办条目的外层是 `.dpcard.todo`，
    // `data-todo-index` / `data-todo-key` 都挂在**卡片**上。
    // **日记条目**：右键弹「修改… / 删除 / 取消」（和待办一样，2026-11-10）。
    var diaryEl = e.target && e.target.closest ? e.target.closest('.dpdiaryrow') : null;
    if (diaryEl && DP.open) {
      var diaryId = diaryEl.getAttribute('data-diary-id') || '';
      if (diaryId) {
        post('diaryMenu', {
          day: DP.day,
          id: diaryId,
          x: e.clientX,
          y: e.clientY
        });
      }
      return;
    }

    var todoEl = e.target && e.target.closest ? e.target.closest('.dpcard.todo') : null;
    if (todoEl && DP.open) {
      var idx = parseInt(todoEl.getAttribute('data-todo-index'), 10);
      var key = todoEl.getAttribute('data-todo-key') || '';
      if (key) {
        var found = findTodoByKey(DP.day, key);
        post('todoMenu', {
          day: DP.day,
          key: key,
          index: isNaN(idx) ? -1 : idx,
          identifier: todoEl.getAttribute('data-todo-identifier') || '',
          calendarIdentifier: todoEl.getAttribute('data-todo-calendar') || '',
          title: found ? (found.t.title || '') : '',
          due: found ? (found.t.due || '') : '',
          x: e.clientX,
          y: e.clientY
        });
        return;
      }
      // 正在完成 / 删除、已经不在原生数据里的待办 → 右键什么都不做。
      // 不能落到下面的「课程格子右键」，那会弹出课程编辑菜单。
      return;
    }
    post('contextmenu', hitPayload(e.clientX, e.clientY));
  }, true);

  // 命中测试：找出指针下面那个格子（.cell），返回 day / block / courseID / name
  function hitPayload(x, y) {
    var el = document.elementFromPoint(x, y);
    var cell = null;
    if (el && el.closest) cell = el.closest('.cell');
    var p = { x: x, y: y, day: null, block: null, courseID: '', name: '' };
    if (cell && cell.dataset) {
      if (cell.dataset.day !== undefined) p.day = parseInt(cell.dataset.day, 10);
      if (cell.dataset.block !== undefined) p.block = parseInt(cell.dataset.block, 10);
      p.courseID = cell.dataset.cid || '';
      p.name = cell.dataset.name || '';
    }
    return p;
  }

  // 供原生侧「查看详情」：在网页里展开某门课的详情浮层
  // ---- 图钉（2026-11：视觉搬进网页层）----
  //
  // 原生把 SF Symbol 渲染成 2x PNG 注入进来，网页只负责显示；
  // 「固定 / 未固定」两态只换图，尺寸 / 位置完全一致。
  var PIN_IMG = { hollow: '', solid: '' };
  var pinPinned = false;

  function applyPinVisual() {
    var el = document.querySelector('.ttlpin');
    if (!el) return;
    var src = pinPinned ? PIN_IMG.solid : PIN_IMG.hollow;
    if (src && el.getAttribute('src') !== src) el.setAttribute('src', src);
    el.classList.toggle('on', pinPinned);
    el.title = pinPinned ? '解锁课表' : '固定课表';
  }

  window.ttSetPinImages = function (hollow, solid) {
    PIN_IMG.hollow = hollow || '';
    PIN_IMG.solid = solid || '';
    applyPinVisual();
  };

  // 原生同步「固定状态」（点热区 / 菜单 / 恢复记忆都走这里）。
  window.ttSetPinned = function (pinned) {
    pinPinned = !!pinned;
    applyPinVisual();
  };

  window.ttSelectCourse = function (day, block, cid) {
    var list = (S && S.courses) || [];
    for (var i = 0; i < list.length; i++) {
      var c = list[i];
      if (c.day === day && c.block === block && (!cid || c.courseID === cid)) {
        sel = c;
        render();
        return true;
      }
    }
    return false;
  };

  // =====================================================================
  // 日期覆盖层：暴露给原生的接口（契约见规格 8.3）
  // =====================================================================

  /// 把「本地乐观条」的 id（`local-…`）解析成原生真实 id。
  /// 解析不了（原生还没推回来）返回空串。
  function resolveDiaryID(id) {
    if (!id) return '';
    if (String(id).indexOf('local-') !== 0) return id;
    var data = panelDataFor(DP.day) || {};
    var list = data.diary || [];
    var pending = (DP.diaryPending || []).filter(function (x) { return x.id === id; })[0];
    if (!pending) return '';
    for (var i = 0; i < list.length; i++) {
      var d = list[i];
      if (String(d.id || '').indexOf('local-') === 0) continue;
      if ((d.title || '') === (pending.title || '') &&
          (d.body || '') === (pending.body || '') &&
          (d.time || '') === (pending.time || '')) {
        return d.id;
      }
    }
    return '';
  }

  /// 原生右键菜单选完之后回调（`修改…` / `删除`）。
  window.ttDiaryMenuAction = function (action, payload) {
    if (!payload || !payload.id) return;
    if (action === 'delete') {
      // ⚠️ 乐观插入的那条 id 是 `local-…`，原生不认识 ——
      // 先按「标题 + 正文 + 时间」找到对应的**真实**条目再删（2026-11-10）。
      var realID = resolveDiaryID(payload.id);
      if (!realID) {
        // 原生还没推回来 → 排个队，等数据到了再补发。
        DP.diaryPendingDeletes = DP.diaryPendingDeletes || [];
        DP.diaryPendingDeletes.push(payload.id);
        DP.diaryPending = (DP.diaryPending || []).filter(function (p) {
          return p.id !== payload.id;
        });
        renderPanel();
        return;
      }
      post('diaryDelete', { id: realID, day: DP.day });
      // ⚠️ 本地也要**立刻**把这条从数据里摘掉（2026-11-10）：
      // `renderPanel` 有「内容没变就早退」的指纹，只删 pending 不改数据的话
      // 这一行会一直留在界面上（自检里就是「右键删除之后还有那一行」）。
      var stripDiary = function (list) {
        return (list || []).filter(function (e) { return e.id !== payload.id; });
      };
      if (typeof S !== 'undefined' && S && S.dayPanel && S.dayPanel.day === DP.day) {
        S.dayPanel.diary = stripDiary(S.dayPanel.diary);
      }
      if (DP.cache && DP.cache[DP.day]) {
        DP.cache[DP.day].diary = stripDiary(DP.cache[DP.day].diary);
      }
      DP.diaryPending = (DP.diaryPending || []).filter(function (p) {
        return p.id !== payload.id;
      });
      renderPanel();
      return;
    }
    if (action === 'edit') {
      var data = panelDataFor(DP.day) || {};
      var list = data.diary || [];
      var hit = null;
      for (var i = 0; i < list.length; i++) {
        if (list[i].id === payload.id) { hit = list[i]; break; }
      }
      if (hit) openDiaryForm('edit', hit);
    }
  };

  // 原生 push 状态用（等价于 ttUpdate 的 dayPanel / dayFlags 扩展）。
  // 传 { dayPanel: {...}, dayFlags: {...} }，可以带，也可以只带其中一个。
  window.ttDayPanelSetState = function (json) {
    var next = json;
    if (typeof next === 'string') {
      try { next = JSON.parse(next); }
      catch (e) { window.__ttDayPanelParseError = String((e && e.message) || e); return; }
    }
    if (!next) return;
    try {
      // ⚠️ **「空中间态」保护**（2026-11）：
      //
      // 原生 open（换天 / 换列）会**先推**一份「只有节日、待办 / 日程为空」
      // 的中间态，再异步查 EventKit 推全量（loadContent 的 resetImmediately）。
      // 网页跟随模式换列会补发 `datePanelOpen` → 原生反复 open →
      // **快速换列时异步全量回包会被原生竞态防线丢弃**（contentToken 对不上）→
      // 这份空中间态就变成「最终」状态 → 待办 / 日历行程永远显示空
      // （用户反馈：「待办怎么都没了」）。
      //
      // 保护：**刚请求过的那列**（requestedDay === day）发来的空中间态一律忽略，
      // 保留旧缓存 / 旧 S.dayPanel，等异步全量回包再覆盖。
      // 用户操作（勾选 / 删除待办）后的真实空列表不受影响（那时 requestedDay 已清）。
      var skipPanelRender = false;
      if (Object.prototype.hasOwnProperty.call(next, 'dayPanel')) {
        var np = next.dayPanel;
        var npDay = (np && typeof np === 'object' && typeof np.day === 'number')
          ? np.day : null;
        var isEmptyMid = np && Array.isArray(np.todos) && np.todos.length === 0 &&
                         Array.isArray(np.events) && np.events.length === 0;
        if (isEmptyMid && DP.requestedDay === npDay) {
          skipPanelRender = true;
        } else {
          S = S || {};
          S.dayPanel = np;
          // ⚠️ 收到数据 → 请求标记作废：这一列已经有缓存了，
          // 之后 openPanel 的「数据缺失补发」不会再请求。
          DP.requestedDay = null;
          // 同样要缓存 —— 否则换列时对不上就没有数据可显示。
          if (np && typeof np === 'object') {
            cacheDayPanel(np);
            // 这条接口是「直接注入完整状态」（自检 / 出图），
            // 没有后续的 EventKit 回包 —— 视作已加载，免得 openPanel 又去请求。
            if (typeof np.day === 'number') DP.loaded[np.day] = true;
          }
        }
      }
      if (Object.prototype.hasOwnProperty.call(next, 'dayFlags')) {
        S = S || {};
        S.dayFlags = next.dayFlags;
      }
      // ⚠️ **7 天各自的「今日详情」**（2026-11）。
      if (Object.prototype.hasOwnProperty.call(next, 'dayFestivals')) {
        DP.dayFestivals = next.dayFestivals || {};
      }
      // 原生推来的 dayPanel 可能带了 day —— 对不上当前列就不显示数据
      // （空中间态被忽略时整帧跳过重绘，面板保持旧数据不闪空）。
      if (!skipPanelRender && DP.open && DP.day !== null) {
        renderPanel();
        applyNarrowLimit();
        positionPanel();
      }
    } catch (e) {
      window.__ttDayPanelError = String((e && e.stack) || (e && e.message) || e);
    }
  };

  // 原生：**课表正在被拖动 / 拖完了**（2026-11 修「表头往下滑，面板乱闪」）。
  //
  // 拖动时窗口跟着鼠标走，指针在窗口里的相对位置一直在变 ——
  // 跟随模式会把面板一个接一个地打开 / 收起。
  // 原生在 `mouseDown` 之后判定为拖动时置 true、松手时置 false。
  window.ttDayPanelDragging = function (dragging) {
    DP.dragging = !!dragging;
    if (!DP.dragging) {
      // 拖完了：让下一次指针移动从头算，别把拖动过程中算出来的
      // 「当前列」当成用户想去的地方。
      DP.hoverDay = DP.day;
    }
  };

  // 原生：**原生菜单开着 / 关了**（2026-11）。
  //
  // 菜单弹出时指针必然离开卡片 → 原生判定「指针离开了课表」→
  // 网页收到 `ttLiveHoverClear()`。这段时间里**不能**收覆盖层
  // （否则用户看到「点删除 / 修改，整个日历闪一下」）。
  //
  // 原生在弹菜单前调 true、菜单关闭后调 false（MenuPresenter 负责配对）。
  window.ttDayPanelMenuOpen = function (open) {
    DP.menuOpen = !!open;
    if (open) {
      // 菜单弹在哪一列，就记住哪一列 ——
      // 菜单期间指针可能移到别的列，但用户要改的是**原来那条**。
      DP.menuDay = DP.day;
    } else {
      // 菜单刚关：如果指针其实还停在卡片上，覆盖层应该**留在原位**，
      // 不要因为「菜单期间指针动过」而换列或收走。
      DP.hoverDay = DP.day;
    }
  };

  // 原生/自检用：**直接打开**某一列的覆盖层（不走 intent 往返）。
  //
  // 为什么要它：网页发 intent → 原生查数据 → 原生推回状态，
  // 这一圈下来覆盖层才出现。自检和出图时没法走那一圈，
  // 直接调它最省事。参数 wide=true 表示直接进宽态。
  window.ttDayPanelOpen = function (day) {
    // 自检 / 出图：状态是直接注入的，**不要**再往原生发 `datePanelOpen`
    // （否则真正的事件循环会把「空数据」推回来，盖掉注入的状态）。
    openPanel(day, false);
    return true;
  };

  // 诊断用：模拟鼠标移动 / 点击表头（自检用）。
  window.__ttDiagMove = function (x, y) { onPointerMove({ clientX: x, clientY: y }); };
  window.__ttDiagClick = function (day) { onHeaderPick(day); };

  // 原生 / 自检查询：「添加待办」的输入区**开着没有**。
  //
  // ⚠️ **必须看可见性，不能只看元素在不在**（2026-11-09 起）。
  //
  // 「添加待办」的表单现在是**稳定元素**（建一次就留着），
  // 收起时只是被 `display:none` 藏起来 —— 元素还在 DOM 里。
  // 所以 `!!document.querySelector('.dpaddform')` 永远是 true，
  // 判断「开着没有」要用可见性。
  window.ttAddFormVisible = function () {
    var form = document.querySelector('.dpaddform');
    if (!form) return false;
    if (form.offsetParent === null) return false;
    var r = form.getBoundingClientRect();
    return r.height > 0 && r.width > 0;
  };

  // 原生查询：当前是否有覆盖层、是哪一列、什么状态
  window.ttDayPanelIsOpen = function () {
    return {
      open: !!DP.open,
      day: (DP.open && DP.day !== null) ? DP.day : null,
    };
  };

  // 原生强制收起（拖动课表时用）
  window.ttDayPanelClose = function () {
    closePanel(true);
    post('panelRect', { open: false });
  };

  // 原生回报「添加待办」的结果（2026-11 加）。
  //
  // ⚠️ 以前失败是**完全静默**的 —— 用户点了「添加待办」什么反应都没有。
  window.ttDayPanelTodoAddResult = function (res) {
    if (!res || typeof res !== 'object') return;
    DP.addError = res.ok ? '' : (res.message || '添加失败');
    if (DP.open && DP.day !== null) {
      renderPanel();
      applyNarrowLimit();
    }
  };

  // ---- 鼠标事件接线 ----
  //
  // 桌面层窗口不是 key window，收不到 mouseMoved，
  // 所以覆盖层的跟随逻辑不能只靠 DOM 事件 ——
  // 原生在模式 B 下会用 ttLiveHover(x, y) 同步指针位置（见下面的 HOVERABLE 段）。
  // 快照模式（A）下由真实鼠标事件驱动。
  document.addEventListener('mousemove', function (e) {
    onPointerMove(e);
  }, true);

  // ⚠️ **`document` 上的 `mouseleave` 捕获监听只对快照模式有效**（2026-11 修）。
  //
  // `mouseleave` 本身不冒泡，但捕获阶段的监听挂在 `document` 上，
  // 会**收到后代元素的 mouseleave**：指针从 `.dpcard` 移到 `.dpcards`，
  // 再到 `.dpbody`、`.daypanel`，document 都能看到这些「离开」。
  // 以前无条件把这些事件当成「指针离开课表」→ `onPointerLeave()`
  // → `fadeOutPanel()`，于是出现用户反馈的现象：
  //
  //   · 点「添加待办」之后面板直接消失；
  //   · 点圆圈勾选完成之后面板直接消失；
  //   · 鼠标一动又回来了（`fadeOutPanel` 保留 following=true）。
  //
  // 这两步都会走 `renderPanel()` 重建面板 DOM，重建时指针下方
  // 的旧节点被摘掉，浏览器补发一串 mouseleave，`relatedTarget`
  // 还是课表格子（`cell empty`）—— 指针根本没离开课表，却被判成离开。
  //
  // 修法：
  //   · 直上屏模式（B）：**不注册**这个监听。原生 `ttLiveHoverClear()`
  //     只在指针真正离开卡片时调用（见下面 HOVERABLE 段），是权威来源。
  //   · 快照模式（A）：保留监听，但 `relatedTarget` 仍在文档内时忽略 ——
  //     那不是离开课表，只是文档内部的元素切换。
  if (!window.__TT_LIVE) {
    document.addEventListener('mouseleave', function (e) {
      if (e.relatedTarget && document.documentElement.contains(e.relatedTarget)) return;
      onPointerLeave();
    }, true);
  }

  // ⚠️ **不要用 `window` 的 `blur` 来判断「指针离开卡片」**（2026-11 修）。
  //
  // 以前的写法是：
  //   window.addEventListener('blur', function () { onPointerLeave(); });
  //
  // 但网页的 `window.blur` **不只是「指针离开」** —— 窗口交出 key /
  // first responder 时也会触发。而「添加待办」输入框的 Enter / Esc / 失焦
  // 本来就会让原生 `resignKey()`（见 DesktopWindow.setTextInputMode），
  // 于是用户**每按一次回车**，网页都会误以为「指针离开了」→
  // `onPointerLeave()` → `fadeOutPanel()` → 整个瀑布面板收起消失，
  // 直到鼠标再动一下、跟随模式把它重新打开
  // （用户反馈：「输入完待办点回车，整个面板突然不见，鼠标一动又出现」）。
  //
  // 指针真正离开卡片的判断有两条可靠通道，不需要 blur：
  //   · 快照模式：上面的 `document` `mouseleave`；
  //   · 模式 B：原生在指针离开卡片时调 `ttLiveHoverClear()`（见下面）。

  // ---- 实验模式 B（DT_LIVE=1）：网页直接上屏 ----
  //
  // 桌面层窗口不是 key window，收不到 mouseMoved，
  // 网页的 :hover 不会自己触发。原生会用全局鼠标监控算出指针位置，
  // 再调用 ttLiveHover(x, y)（CSS 像素）把这个位置同步过来。
  //
  // 注意：合成事件不会驱动 CSS 的 :hover 伪类，
  // 所以这里用「tt-hover 类」手动模拟悬停态，
  // CSS 里补了 .tt-hover 的对应规则（与 :hover 一致）。
  //
  // 只有 window.__TT_LIVE 为真时才装这些钩子 ——
  // 快照模式（方案 A）下网页行为与之前完全一样。
  if (window.__TT_LIVE) {
    // 新增的可悬停元素要一起加进来，否则模式 B 下 hover 桥接命不中它们，
    // 会出现「快照模式有悬停效果 / 直上屏模式没有」的两种表现。
    //   .hcell.pick  表头（点日期）—— 纯变色提示
    //   .dpcard.todo 待办卡片（点 = 打勾）
    //   .dpadd       「＋ 添加待办」
    //   .dpok        时间行右侧的「取消」
    //
    // ⚠️ **卡片化之后**待办条目是 `.dpcard.todo`（不再是 `.dptodo`）——
    // 白名单不跟着改的话，模式 B 下待办卡片就没有悬停反馈。
    var HOVERABLE = '.wkchip,.arrow,.nowbtn,.setbtn,.course,.close,.collapsebtn'
      + ',.hcell.pick,.dpcard.todo,.dpadd,.dpok,.dpeditbtn';
    var hoveredEl = null;

    // 实验用探针（DT_LIVE_PROBE=1 时才装）：把网页真正收到的事件记下来，
    // 用来判断「真实鼠标事件到底有没有到 webview」。
    if (window.__TT_LIVE_PROBE) {
      window.__ttEventLog = [];
      ['mousemove', 'mousedown', 'mouseup', 'click', 'contextmenu'].forEach(function (t) {
        document.addEventListener(t, function (e) {
          var tgt = e.target;
          window.__ttEventLog.push(t + '@' + Math.round(e.clientX) + ',' + Math.round(e.clientY)
            + '->' + (tgt ? (tgt.className || tgt.tagName) : 'null'));
          if (window.__ttEventLog.length > 40) window.__ttEventLog.shift();
        }, true);
      });
    }

    function clearHover() {
      if (hoveredEl) {
        hoveredEl.classList.remove('tt-hover');
        hoveredEl = null;
      }
    }

    window.ttLiveHover = function (x, y) {
      var el = document.elementFromPoint(x, y);
      var target = null;
      if (el && el.closest) target = el.closest(HOVERABLE);
      if (target !== hoveredEl) {
        clearHover();
        if (target) {
          target.classList.add('tt-hover');
          hoveredEl = target;
        }
      }
      // 指针位置同步 → 覆盖层的跟随逻辑也得跟着走
      // （桌面层窗口收不到 mouseMoved，只靠 DOM 事件是走不动的）。
      onPointerMove({ clientX: x, clientY: y });
      // 同时派发一个真实的 mousemove 事件，页面里若有 JS 监听也能收到
      if (el) {
        el.dispatchEvent(new MouseEvent('mousemove', {
          bubbles: true, cancelable: true, view: window, clientX: x, clientY: y
        }));
      }
    };

    window.ttLiveHoverClear = function () {
      clearHover();
      // 指针移出卡片 → 覆盖层淡出消失
      onPointerLeave();
    };
  }

  // ⚠️ 启动阶段的异常**必须记下来**：以前这里直接调，哪里抛一下，
  // 后面的定时器就全不装了（表现为「时钟永远停在某一刻」）。
  try {
    render();
  } catch (e) {
    window.__ttBootError = 'render: ' + String((e && e.stack) || e);
  }
  try {
    // 时钟 / 状态条自己走表：原生推送在数据没变时不会重画顶部（否则表头又要闪），
    // 所以不能让它们等推送来刷新。
    setInterval(updateLiveTexts, 10000);
    // 页面从后台回来（例如显示器休眠后唤醒）立刻对一次表。
    document.addEventListener('visibilitychange', function () {
      if (!document.hidden) updateLiveTexts();
    });
    // 自检入口：立刻刷新一次顶部文字，并标记定时器已装上。
    window.__ttUpdateClock = updateLiveTexts;
    window.__ttClockTimer = true;
  } catch (e) {
    window.__ttBootError = (window.__ttBootError || '') + ' tail: ' + String((e && e.stack) || e);
  }
})();

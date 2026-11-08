# Spike 结论 · WKWebView.pageZoom 坐标语义（2026-11-06）

用独立程序（`/tmp/dt-spike/spike.swift`，不改项目源码）实测 `WKWebView.pageZoom`。

## 实测数据

| scale | view 宽 | CSS 视口宽 (body) | ratio | `.hcell` 宽 (CSS px) | `.hcell` 左 (CSS px) |
|---|---|---|---|---|---|
| 1.00 | 1400 | 1148 | — | 118.859 | 421.703 |
| 0.85 | 975.8 | 1148 | **0.850003** | 118.860 | 421.691 |
| 1.15 | 1320.2 | 1148 | **1.150011** | 118.873 | 421.685 |

## 结论

1. **CSS 视口宽度恒为 1148**（`Timetable.html` 的 `body { width: 1148px }`），
   **不随 `pageZoom` 变**。→ 网页层不需要改 CSS 尺寸。
2. **版式完全不变**：`.hcell` 宽度恒为 118.86 CSS px，与 scale 无关。
   → `Timetable.css` 的 268 处 px **一处都不用改**。
3. **1 个 CSS px 在屏幕上占恰好 `scale` 个 view 点**
   （ratio = view宽 / CSS视口宽 = scale，误差 < 1e-5）。
4. **`elementFromPoint` 的参数是 CSS 坐标**（直接传 CSS 坐标命中正确 ✅）。
5. **原生 view → CSS 换算 = `css = view ÷ scale`** ✅ 两个极端档都验证命中正确。

## 对实现的直接影响

- `WebCardRenderer.cssPoint(_:)` 现在只翻 y（`webView.bounds.height - point.y`），
  要改成**先 ÷ scale 再翻 y**。
- 四条命中链路都要用换算后的坐标：
  `forwardClick` / `forwardHover` / `forwardLiveHover` / `hitTestInWeb`。
- `Timetable.html` 的 `body { width: 1148px; padding: 90px }` **必须改成按 scale 算**
  （`width: calc(1148px * var(--tt-scale))` 或由原生注入 CSS 变量），
  否则卡片在网页里的位置和原生窗口对不上。

## 验证脚本

```bash
swiftc -O /tmp/dt-spike/spike.swift -o /tmp/dt-spike/spike && /tmp/dt-spike/spike
```
（结果 6/7 通过；唯一失败项 Q1 是基线断言写死了 clientWidth=1148，
但基线时 webView 给的是窗口宽 1400，属断言问题非逻辑问题。）

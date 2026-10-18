# macOS 27 设计规范（FHCPEM 实测版）

本文件不是对 Apple 文档的转述，而是**在本机 macOS 27 上用 AppKit/SwiftUI 真实控件量出来的数值**。凡是写"实测"的地方都可以复现（见文末探针代码）。

用途：任何新增控件、圆角、间距都必须先查本表；查不到就先测，不要把数字拍脑袋写进代码。

---

## 1. 控件尺寸基线

| 语义 | 高度 | 来源 |
| --- | --- | --- |
| `NSButton` mini | 16 pt | 实测 `sizeToFit` |
| `NSButton` small | 20 pt | 实测 |
| `NSButton` regular | 24 pt | 实测 |
| `NSButton` large | 28 pt | 实测 |
| `NSTextField`（rounded bezel） | 24 pt | 实测 |

**决策**：本应用的按钮高 **30 pt**、输入框高 **26 pt**。理由：面板可用宽度只有 340 pt，比系统 regular 稍大一点能提高点击命中率，同时与 26 pt 输入框形成 4 pt 的高度差，视觉上主次分明。

## 2. 字号基线

| 语义 | 点值 | 用途 |
| --- | --- | --- |
| body | 13 | 系统正文 |
| small | 11 | 次要说明 |
| mini | 9 | 极小标注 |
| label | 10 | 字段名 |
| menu | 13 | 菜单栏 |

**本应用实际使用**：页面标题 17 semibold · 分区标题 11.5 medium · 正文 12 · 说明 10 · 页脚 11 · 菜单栏 11 medium（等宽数字）。

## 3. 圆角定义（核心）

### 3.1 实测依据

| 被测量对象 | 实测半径 |
| --- | --- |
| `NSTextField`，高 24 pt，rounded bezel | ≈ **6.6 pt** |
| `NSWindow`（titled），私有 `_cornerRadius` | **16 pt** |
| `NSButton` `.rounded`，高 16/20/24/28 | **完整胶囊**（半径 = 高度 ÷ 2），不是固定圆角矩形 |

### 3.2 令牌表（`Theme.Radius`）

| 令牌 | 值 | 用于 | 依据 |
| --- | --- | --- | --- |
| `.window` | 16 | 面板最外层 | 实测窗口圆角 |
| `.panel` | 10 | 分组卡片 | 同心推导 |
| `.panelInset` | 3 | 卡片内边距 | 同心推导 |
| `.row` | 7 | 卡片内单行 / 文本块 | 实测 6.6 取整 |
| `.control` | 6 | 输入框 | 实测 6.6，26 pt 高时略收 |
| `.button` | `buttonHeight / 2` = 15 | 主/次按钮 | 实测胶囊 |
| `.buttonHeight` | 30 | 按钮高 | 本应用决策 |
| `.chip` | 5 | 徽标 / 芯片 | 与 10 pt 字号匹配 |

### 3.3 同心圆角法则

> **外半径 = 内半径 + 内边距**

卡片半径 10、内缩 3 → 行半径必须是 7，两条弧线才光学平行。
若卡片改为 `R`，内部行必须同步为 `R − inset`；**不允许**内外都写同一个数值，那样看起来内层更"方"。

这条规则已落在 `Theme.Radius` 的注释里，并在 `MenuBarGeometryTests` 之外由代码结构保证（行半径只引用令牌，不写字面量）。

## 4. 浮层与材质

### 4.1 面板尺寸（实测）

`NSPopover` 在每边固定留 **13 pt** 箭头边距：

```
内容 340 × 560  →  窗口 366 × 586
```

**决策**：设计稿只按 **340 × 560** 出图；窗口多出的 26 pt 是平台边框，不追、不补、不试图取消。已启用 `hasFullSizeContent = true`，内容不会被二次内缩。

### 4.2 材质枚举（实测 rawValue）

`titlebar 3 · menu 5 · popover 6 · sidebar 7 · headerView 10 · windowBackground 12 · hudWindow 13 · contentBackground 18 · underWindowBackground 21`

**优先级**：

1. macOS 26+ 且未开启「降低透明度」→ `glassEffect(_:in:)` + `GlassEffectContainer`
2. 否则 → 半透明填充 + `.regularMaterial` 回退
3. 永远保留 0.5 pt hairline 描边，保证在纯色壁纸上也有边界

### 4.3 菜单栏

| 项 | 值 |
| --- | --- |
| 菜单栏高度 | 22 pt（实测 `NSStatusBar.system.thickness`） |
| 图标画布高 | 18 pt |
| 图标类型 | **template image**（系统反色，禁止硬编码黑白） |
| 柱形 | 宽 3 pt、间隙 1.5 pt、最高 12 pt（1:2:3:4），上下各留 3 pt，围绕中线居中 |
| 两档预留宽度 | 33.5 / 79.5 pt |
| 两档实测宽度 | 47.5 / 93.5 pt（含系统内边距） |

图标内部全部落在 **0.5 pt 网格**：柱宽 3、间隙 1.5、最高柱 12、柱区 16.5。2x 屏上每根柱宽 6 像素、间隙 3 像素，边缘锐利；柱形围绕中线放大到 12 pt，看上去更饱满但不顶到画布边缘。

## 5. 动效

| 场景 | 曲线 | 时长 |
| --- | --- | --- |
| 悬停 / 按下 | `Theme.quick` | ≈0.12 s |
| 页签切换 | `.smooth` | 0.22 s |
| 数值变化 | `contentTransition(.numericText())` | 系统默认 |

**禁令**：不要对 `route`（页面切换）做隐式动画。曾因 `.animation(Theme.page, value: model.route)` 导致面板完全打不开。

## 6. 交互范式（菜单栏工具）

| 操作 | 行为 | 为什么 |
| --- | --- | --- |
| 左键单击图标 | 切换面板 | 菜单栏工具的标准预期 |
| 右键 / Control+左键 | 原生 NSMenu：打开面板 / 立即刷新 / 显示样式（仅信号强度 · 信号强度 + 网速）/ 退出 | `MenuBarExtra` 做不到，故改用 `NSStatusItem` |
| 点击面板外 | 关闭面板 | 应用失活即关闭；不用 `.transient`（输入时会误关） |
| `Esc` | 关闭面板 | 只关面板，绝不退出应用 |
| `⌘W` | 关闭面板 | 同上 |
| `⌘Q` | 退出应用 | accessory 应用必须有隐藏主菜单才生效 |
| 页脚电源键 | 退出应用 | 可见出口，避免"退不掉" |

## 7. 无障碍

| 要求 | 做法 |
| --- | --- |
| 不依赖颜色 | 「区分而不依赖颜色」开启时，异常状态点由圆形变菱形 |
| 信号不可见 | `SignalBars` 有 VoiceOver 文案（"信号 3 档" / "信号未知" / "无信号"） |
| 未知态可辨 | 未知画空心柱，0 格画实心淡柱 |
| 对比度 | 所有文字 ≥ `.secondary`；错误文案用 `Theme.negative` 且有图标 |

## 8. 键盘

Tab 顺序与视觉顺序一致；输入框回车提交；按钮回车触发默认动作；`Esc` 关闭浮层。

---

## 附：复现探针

以下数值来自临时 Swift 探针（不随产品发布）：

```swift
// 控制高度
for size in [NSControl.ControlSize.mini, .small, .regular, .large] {
    let b = NSButton(title: "x", target: nil, action: nil)
    b.controlSize = size; b.bezelStyle = .rounded; b.sizeToFit()
    print(size, b.frame.height)          // 16 / 20 / 24 / 28
}
// 窗口圆角
let w = NSWindow(contentRect: ..., styleMask: [.titled], ...)
print(w.value(forKey: "_cornerRadius"))  // 16
// 菜单栏
print(NSStatusBar.system.thickness)      // 22
```

圆角测量方法：把控件以 16 倍放大光栅化，扫描最底部一行"完全填充"的像素，其左侧内缩量即为半径（单位 pt）。


---

## 9. 表面与排版细化（2026-10-18 第四轮）

### 9.1 面板不是纯色

单一 3.5% 灰度看起来"没做完"。`Panel` 现在由三层叠成：

1. **渐变填充**：`0.055 → 0.028` 自上而下，制造极轻的体积感；
2. **0.5 pt 描边**：`hairline`（7.5% 前景），负责边界；
3. **顶部内高光**：0.5 pt 白色 10% → 透明，只保留 1 px，模拟系统分组表格边缘受光。

三层都极轻，叠起来才有"被光照过"的感觉，任何一层单独加重都会变成玻璃卡片。

### 9.2 分区标题

分区标题是**标签**而非正文：11.5 pt semibold、`primary` 62% 不透明度、字距 +0.2。此前用 `.secondary` 偏灰，和正文说明文字混在一起，层级不清。

### 9.3 数值排版

所有数值一律**等宽数字**（`monospacedDigit`）：速率、流量、PCI、NCI、IP、时间。比例数字在刷新时会让整行宽度跳动，等宽数字不会。

概览主数值 25 pt semibold（原 27 pt），配合收紧的行距，让一屏能多放两行信息而不显拥挤。

### 9.4 一屏原则

概览页的目标是**不滚动就能看完**：网络制式、Wi-Fi、四项流量、六项连接事实、九项蜂窝指标。任何新增字段都必须先问"能不能从别处删掉同等级的内容"，否则页面会退回到需要滚动的状态。

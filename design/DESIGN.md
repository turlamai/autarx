# Autarx DESIGN.md — 视觉与交互契约（单一真源）

原型（`design/prototype/`）与三平台原生实现（`macos-host/`、`windows/`、`linux/`）都遵循本文件；改视觉先改这里，再同步实现。
Tokens 提取自 `docs/family.css`（site-kit v1.0.3，家族设计系统单一真源）现行值；三平台宿主当前用系统默认样式，本契约是品牌层首次落进工作台——原型到实现零翻译成本，平台 chrome（窗口/菜单/文件选择器）保持原生。

## Brief（2026-11-11）

- **目标**：不是从零重设计——工作台 IA 已成型（Workspace / Objects / ECUs / Unresolved / Communication 五节，SwiftUI/WinUI 3/GTK4 三端一致）。本次把家族品牌 tokens 首次落进工作台，并让「路径、引用、diff、finding」这些工程内容站上主角位：校验结果即时可读、每条 finding 给出修复路径、破坏性编辑（patch apply）防错一致。原型同时覆盖 CLI 已有能力升格为工作台视图的两节：Diff（语义对比 + ECU 影响分析）与 Patch（受控编辑 plan→apply→undo）——引擎能力已存在，无新功能。
- **原型范围**（6 屏 × 亮/暗）：① Workspace 概览（英雄屏，含索引完成反馈条）② Objects 检索 + 引用 Inspector ③ Diff + ECU 影响分析（内容主角）④ Unresolved findings（失败态 + 修复路径 + 全清空态对照）⑤ Patch 计划预览（破坏性操作确认范式）⑥ 设置（vendor / 更新 / MCP / 外观）。ECUs（Objects 的 ecu 过滤态）与 Communication 两节本次不做独立屏，导航中保留入口。
- **Exit 条件**：6 屏关键状态齐（空态/进行态/失败态成对）+ 交互逻辑定稿 + HIG 清单全过 + 用户评审通过。
- **不在范围**：新引擎能力、RPC 契约变更、商业/定价 UI、Linux/Windows 特有 chrome 的像素级还原、i18n（现有 UI 为英文单语）。

## 设计原则（HIG 内核）

- **路径即内容**：AUTOSAR 绝对路径是本产品的身份与主角，一律等宽字体、可选中复制；永不显示 XML 行号（引擎红线进 UI）。
- **校验反馈即时明确**：unresolved / duplicate / breaking 在出现处（行内徽标、健康卡、diff 行）就地标红，不藏在菜单里；每条 finding 附修复路径（Trace / 在 Objects 中打开 / 复制路径）。
- **措辞诚实**：Autarx 的 validate 只是结构检查，界面绝不出现「AUTOSAR compliant / production valid」；vendor validate 只中继 vendor 自己的结论，Autarx 从不代言。
- **防错一致**：patch plan 先行、apply 必确认（danger 色确认按钮 + 自动备份 + Undo 承诺同屏可见）；「无 raw-write 通道」的引擎边界在 UI 上等价成立。
- **层级克制**：bg < surface < 覆层三层足够；accent 只给交互与状态，语义 kinds 全部中性 chip——语义类别不是交互，不抢注意力。

## Tokens（与实现 1:1）

来源：`docs/family.css`（site-kit v1.0.3）逐值提取；`--ok / --warn / --danger` 为推导值——家族 kit 尚无状态色，依据 = 与 terracotta accent 可区分 + 亮暗两态对白底/深底均达 WCAG AA。

| Token | Light | Dark | 用途 |
|---|---|---|---|
| `--bg` | `#faf8f5` | `#16120f` | 画布 |
| `--surface` | `#ffffff` | `#1f1a16` | 卡片/Inspector/浮层 |
| `--raised` | `#f3efe9` | `#262019` | 悬浮/选中/输入底 |
| `--raised-2` | `#ece6dd` | `#2e2721` | 按下/更强悬浮 |
| `--line` | `rgba(32,27,22,.12)` | `rgba(241,236,229,.13)` | 分隔 |
| `--line-strong` | `rgba(32,27,22,.24)` | `rgba(241,236,229,.26)` | 控件描边/输入框 |
| `--ink` | `#201b16` | `#f1ece5` | 主文字/路径 |
| `--mute` | `#5d554c` | `#a89f93` | 次级文字 |
| `--faint` | `#8a8177` | `#7a7166` | 辅助/元信息 |
| `--accent` | `#d97757` | `#e08a6b` | 选中/链接/进行态/主按钮 |
| `--accent-strong` | `#a94e31` | `#d97757` | 亮底上的 accent 文字/按压 |
| `--accent-soft` | `rgba(217,119,87,.12)` | `rgba(224,138,107,.14)` | accent 弱底（选中行/徽标） |
| `--on-accent` | `#ffffff` | `#1d120c` | accent 实底上的文字 |
| `--ok` | `#2e7d46` | `#7dce9c` | resolved / 全清 / detected |
| `--ok-soft` | `rgba(46,125,70,.10)` | `rgba(125,206,156,.14)` | ok 弱底 |
| `--warn` | `#9a6b08` | `#e3b25e` | unknown / orphan / 计划告警 |
| `--warn-soft` | `rgba(154,107,8,.10)` | `rgba(227,178,94,.13)` | warn 弱底 |
| `--danger` | `#bf3b30` | `#f2857b` | unresolved / breaking / 破坏性确认 |
| `--danger-soft` | `rgba(191,59,48,.10)` | `rgba(242,133,123,.14)` | danger 弱底 |

- **字体**：界面 `system-ui, -apple-system, "Segoe UI", "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei"`（三平台宿主直接映射系统字体）；路径/引用/diff/JSON 一律 `ui-monospace, "SF Mono", "Cascadia Code", Menlo, Consolas, monospace`。正文 14px/1.55，节标题 16px/700，行标题 600，次级 12.5px，辅助 11.5px。
- **圆角**：窗口 16px · 卡片 12px · 控件 8px（= kit radius l/m/s）。**间距节奏**：4/8/12/16/24。**动效**：140ms cubic-bezier(0.2,0.8,0.2,1)，不过度。
- **语言**：界面文案英文（跟随现有三端 UI 语言）；文档与契约中文。数字/计数用 tabular-nums 对齐。

## 组件词汇

`Sidebar`（INSPECT：Workspace 1 / Objects 2 / ECUs 3 · CHECK：Diff 4 / Unresolved 5 / Communication 6 · CHANGE：Patch 7；foot：Settings + 引擎状态点）· `StatCard`（概览计数卡）· `InventoryTable`（semantic kind → count）· `ObjectRow`（kind chip + short name + 等宽路径 + unresolved 警示）· `RefInspector`（对象头 + outgoing/incoming + Trace 深度）· `DiffSection`（added/removed/modified 组）· `PropertyDelta`（DEFINITION-REF 级参数值变化，旧→新着色）· `FindingCard`（kind 徽标 + source→target + 文件 + 修复路径按钮组）· `SeverityChip`（breaking=danger / info=中性 / orphan=warn / unknown=warn）· `PlanSteps`（Plan→Review→Apply→Done 步进条）· `ConfirmDialog`（破坏性操作，danger 确认按钮）· `Toast`（后台索引/更新进度浮条）。

## 不变式

1. `accent` 只用于：当前选中、链接、进行态、主按钮；语义类别 chip、diff 上下文、finding 徽标一律中性或状态色——accent 不表达错误/危险（danger 专职）。
2. 身份永远是 AUTOSAR 绝对路径，等宽呈现；XML 行号、字节偏移不出现在任何视图中。
3. 校验/校验措辞：结构检查结果用「unresolved / duplicate / inconsistent」陈述；「vendor 校验」永远指 vendor 工具自己的运行，Autarx 只中继与归一化。
4. 亮暗主题成对设计，不存在只有暗态的界面；状态色（ok/warn/danger）两态都必须达 AA 对比。
5. 键盘可达：1–7 切节、/ 聚焦检索、⌘O 打开交付、⌘U 检查更新、R 重建/重校验；所有提示用统一 `kbd` 样式（raised 底、mute 字、6px 圆角）。
6. 破坏性操作（patch apply、close workspace）三件套同屏：明说改什么 + 自动备份位置 + Undo 入口；确认按钮一律 danger 色。

# Autarx DESIGN.md — 视觉与交互契约（单一真源）

原型（`design/prototype/`）与三平台原生实现（`macos-host/`、`windows/`、`linux/`）都遵循本文件；改视觉先改这里，再同步实现。
Tokens 提取自 `site/family.css`（site-kit v1.0.3，家族设计系统单一真源）现行值；三平台宿主当前用系统默认样式，本契约是品牌层首次落进工作台——原型到实现零翻译成本，平台 chrome（窗口/菜单/文件选择器）保持原生。

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

## Tokens（语义与推导依据；值不在此复制）

值类 token 真源 = `site/family.css`（site-kit v1.0.3 家族 kit）；原型 `design/prototype/shared.css` 与 kit 值一一对应，本表只记语义、来源与推导依据。

| Token | 语义 | 来源 |
|---|---|---|
| `--bg --surface --raised --raised-2 --line --line-strong` | 画布/卡片/悬浮/按下/分隔 中性系 | kit 原值 |
| `--ink --mute --faint` | 主/次级/辅助文字三档 | kit 原值 |
| `--accent --accent-strong --accent-soft --on-accent` | 选中/链接/进行态/主按钮 accent 系 | kit 原值 |
| `--ok --ok-soft` | resolved / 全清 / detected | 推导：kit 无状态色，与 terracotta accent 可区分 + 亮暗两态对白底/深底均达 WCAG AA |
| `--warn --warn-soft` | unknown / orphan / 计划告警 | 推导：同上 |
| `--danger --danger-soft` | unresolved / breaking / 破坏性确认 | 推导：同上 |

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


## 平台映射与差异声明（预钉 · 宿主实现时升级为落点表）

统一层（三平台必须一致，`design/prototype/` 原型已锁定）：信息架构、核心流程、快捷键语义、
语义色与层级词汇。因地制宜层（按平台惯例落地，不预画像素）：

| 维度 | macOS | Windows | Linux |
|---|---|---|---|
| 修饰键 | ⌘ | Ctrl | Ctrl |
| 命令入口 | 原生菜单栏 | 菜单栏/命令行内 | 菜单栏 |
| 字体 | 系统栈 + PingFang SC | 系统栈 + Microsoft YaHei | 系统栈 + Noto Sans CJK |
| 原生控件 | SwiftUI 控件 | WinUI 3 控件 | GTK4 控件 |

差异声明纪律：宿主特例必须先写进本节才能实现；未声明的宿主差异按违约处理
（案例：taskly 漂移台账 D8）。

## 工具层原型修订（2026-11-14，覆盖旧 Brief 的定位与范围）

### 产品边界

Autarx 为外部 agent 提供 AUTOSAR 配置查询、受控变更、供应商能力发现和真实校验的工具接口。循环、任务规划、诊断后的修复决策由外部 agent 控制；产品不内置自主任务编排。供应商保留自身校验与代码生成职责，Autarx 不重建其规则引擎。

本轮主入口为 `prototype/tools.html`，覆盖 Capabilities / Configuration / Validation / Agent access 四个连续工作视图。旧六屏保留为先前设计参考，不代表本轮接口已实现。新增接口均为拟议契约，不沿用旧页面所称“12 个工具已暴露”等实现事实。

### 本轮 Exit 条件

- 能力页区分 Available / Blocked / Unsupported，并给出版本、工程绑定和前置条件。
- 配置页支持查询示例值、校验输入、差异预览、明确确认、应用和一次撤销；每次写入生成新 revision。
- 校验页提供显式单次调用、进行态、Passed / Failed / Partial / Execution failed 四种状态、原始输出和历史记录。
- 校验结果绑定 revision、供应商、范围与失败阈值。配置改动后标记旧证据 Stale，不自动重跑。
- agent 页呈现拟议接口、请求与响应示例，支持搜索、类型过滤及复制。
- 用户评审完成后才认定设计冻结；本轮不宣称真实供应商接入、代码生成完成或后端 API 已存在。

### 视觉与交互

延续既有家族暖中性色与 terracotta 品牌，这是现有设计契约的延续，并非新增默认配色。亮态主要操作色使用 `#a94e31`、白字；暗态使用 `#f0a184`、深字，替代旧主按钮的低对比组合。正文 16px / 1.6，标题 32px，节标题 20px，技术元信息 13px；正文与路径按角色分层，完整路径在详情可换行。间距以 4/8 倍数组织，交互反馈 180ms，尊重 reduced-motion。

布局采用桌面侧栏 + 自适应主内容；窄屏改为顶部导航，双栏重排为单栏。四个视图统一复用原型内的 CSS tokens 和组件。单页无外部字体、图像或脚本依赖；不使用真实厂商品牌图像。

英文界面沿用现有契约。中文交付说明。深浅主题通过工作台外观按钮切换；未宣称自动同步系统外观。

### 数据与执行诚实性

- 全部工程值、安装路径、就绪状态、报告和运行记录为明确标注的示例；没有本机扫描、许可证探测或供应商进程。
- Vector 示例能力依据官方 Configurator Classic 6 文档；EB 示例仅体现其官方声明的校验/生成/导入能力，具体版本参数保持未验证；ETAS 不臆造 CLI，显示适配器未接入。
- 参数示例为 CanControllerBaudRate。输入范围仅为原型编辑约束，不代表任何硬件或供应商已认可这些值。
- 诊断为 illustrative fixture，不编造真实 supplier rule ID。原始输出标记 SIMULATED EXECUTION。
- 没有初始执行记录；必须显式调用才产生记录。通过只描述所选范围，不表示全部配置或系统需求成立。
- 缺少工程包绑定、执行失败、部分完成不能转换为 Passed。外部 agent 应能获取原始证据；归一化不得丢弃原始结果。
- 运行数据保存在页面内存，刷新即重置。导出的 JSON 是示例证据。复制受宿主权限限制时给出可手动复制提示。

### 拟议工具接口

`capabilities.list` / `configuration.query` / `configuration.change` / `vendor.validate` / `vendor.generate`。写操作携带预期 revision；实际实现应拒绝过期修改。各适配器保留版本与能力差异，不保证五项能力在所有供应商均可用。本轮未执行真实生成，原型响应诚实返回 not_run。

参考：

- https://help.vector.com/davinci-configurator-classic/en/latest/user-manual/references/cli/dvcfg-b/project.html
- https://help.vector.com/davinci-configurator-classic/en/latest/user-manual/references/cli/dvcfg-b/project-validate.html
- https://help.vector.com/davinci-configurator-classic/en/latest/user-manual/base/using-the-tool/command-line-usage.html
- https://www.elektrobit.com/products/ecu/eb-tresos/studio/

## 供应商覆盖目录增补（2026-11-14）

在当前工作台中增补国产候选：普华 ORIENTAIS、东软睿驰 NeuSAR Configurator、经纬恒润 INTEWORK-EAS-CP 工具链、睿赛德 AUTOSAR CP 配置工具。海外增补 dSPACE SystemDesk、Siemens Capital Embedded Integrator AR Classic（含 VSTAR 产品沿革）、KPIT KSAR C4K。共 10 项覆盖目标，不宣称穷尽市场。

新增项目统一 Planned，实际版本、适配器和自动化契约未确认；不模拟已安装，也不开放校验执行。供应商选择器与 agent 能力清单共用目录。首页统计区分目录目标、国产目标与真实接入数（0）；Vector/EB 的旧可用状态仍仅为示例。

SystemDesk 自动化 API / 官方 MCP 已有公开资料，但面向架构和模型校验，不等同于任意 BSW 工程的供应商校验。国产产品存在不代表公开 CLI 已确认；需要实际版本 SDK/手册与合法可用环境验证。产品证据链接放在各项详情中，不将搜索结果转写成接口承诺。

参考：
- 普华生态资料：https://www.ti.com.cn/partner/cn/ISOFT
- NeuSAR：https://www.reachauto.com/neusar/ccore/
- INTEWORK：https://en.hirain.com/news/341.html
- 睿赛德：https://www.rt-thread.com/col26/list.html
- SystemDesk：https://github.com/dspace-group/SystemDeskMCP
- Siemens：https://www.siemens.com/en-us/products/capital/ee-systems-embedded-software/
- KPIT：https://www.kpit.com/kpit-autosar-portal/


## 2026-11-15 · 原型交互补齐

当前入口为 prototype/tools.html。旧检查界面保留作历史参考，提供返回当前工作台与页面之间的导航；尚无独立界面的分类明确说明范围。

根级 index.html 只负责首次进入主界面；页面切换直接到目标界面，不再保留页面目录。原型运行脚本 prototype-runtime.js / prototype-flow.js 只表达浏览器内的交互合同；正式产品业务仍由既定引擎实现。真实设备、模型和发布服务均未连接。凭据演示不保存密钥，破坏性示例与派发保留确认和取消。

这些是可评审的增量改动，未替用户勾选满意度、HIG 最终验收或设计冻结条件。


## Prototype source checkpoint — 2026-11-15

`index.html` opens the primary prototype directly. Screen-directory launchers have been removed. All local scripts, styles and referenced assets needed by this checkpoint are versioned under this directory; OpenDesign metadata is excluded. This is an editable prototype checkpoint, not a claim that the native product or external services implement these interactions.

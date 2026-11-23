# Autarx — 设计与交互契约

版本：2026-11-20（2026-11-23 按家族最小文档标准瘦身为可核对核心）。本文替代此前散落的原型 Brief、追加修订和过时能力声明。

**真源分工**：颜色、字体栈、字号、圆角、间距与动效时长的具体值以 `design/prototype/shared.css` 为唯一真源（亮暗成对）；本文件只记语义、决策、不变式与退出条件。改值改 CSS，改语义改本文件。

## 目标与边界

Autarx 为外部 agent 提供可发现、可调用、可追溯的 AUTOSAR 工程工具能力：工程上下文、配置查询、受控变更、供应商工具调用和校验证据。循环、任务规划、错误修复决策及重试由外部 agent 负责。

供应商负责其原有模型规则、模块校验与代码生成。Autarx 负责接入并归一化结果，保留执行来源、范围、版本与原始输出，不重建供应商规则引擎。结构检查与供应商校验分开呈现，不使用笼统的“生产有效”或“AUTOSAR compliant”承诺。

本次交付仅为可编辑的浏览器交互原型。没有供应商进程、安装探测、许可证探测、MCP 服务或真实代码生成。工程、配置、运行记录和错误输出均为明确标识的示例。

## 入口与源文件

- `index.html` 直接进入 `prototype/tools.html`，无额外目录或产品宣传页。
- `prototype/tools.html`：Capabilities。
- `prototype/workspace.html`：Workspace。
- `prototype/objects.html`：Objects。
- `prototype/diff.html`、`prototype/patch.html`：统一的 Changes 视图，包含变更预览、应用记录和撤销。
- `prototype/unresolved.html`：Validation 中的 Structural inspection 入口。
- `prototype/settings.html`：Settings。
- `prototype/shared.css`：所有当前入口共用的完整样式及亮暗 tokens。
- `prototype/workbench.js`：所有当前入口共用的示例状态、数据和交互。

旧 `prototype-runtime.js`、`prototype-flow.js` 不再由当前入口引用；保留文件不代表继续使用旧信息架构。所有现有 HTML 入口均渲染统一工作台。Communication、Validation、Agent access 从工作台导航进入，无须新建单独入口文件。

## 信息架构

| 视图 | 主要职责 | 关键交互 |
|---|---|---|
| Workspace | 当前工程、绑定、配置版本、证据摘要 | 前往绑定、配置、变更和校验 |
| Capabilities | 供应商覆盖、产品证据、适配器与环境限制 | 名称搜索、国产/海外过滤、选中详情 |
| Objects | 对象身份、源文件、定义寻址值、引用 | 搜索、kind 过滤、引用跳转、复制路径 |
| Changes | 有预期版本的配置变更 | 输入、预览、确认、应用、丢弃、一次撤销 |
| Validation | 分别显示供应商检查与结构检查 | 显式执行、结果、原始输出、历史选择、导出 |
| Communication | 信号→PDU→帧→ECU 关系 | 沿依赖链定位对象 |
| Agent access | 拟议工具接口和当前上下文示例 | 搜索、类型过滤、复制、跳转操作 |
| Settings | 工程/工具/版本/包绑定及外观 | 表单编辑、缺项反馈、保存、主题切换 |

ECU 通过 Objects 的 ecu 类型和 Communication 关系提供，不再保留无法打开的分类入口。所有主要视图使用相同侧栏、工程上下文、版本提示与状态措辞。

## 核心交互与不变式

### 工程绑定

绑定包含工程名、供应商目标、工具版本、BSW/MCAL/module package 标签、工程文件位置。位置仅为示例文本，不打开本机文件。保存工程名和工具版本为必填；允许保存缺失包或工程位置的绑定，但这些状态阻止执行。

绑定变化增加 environment 版本，使已有供应商证据过期，并丢弃待应用预览及跨绑定撤销快照。绑定未变时不增加版本。

国产候选与未实现适配器可被绑定以表达目标，但不能因此显示成可执行。Vector 仅有明确标识的示例就绪环境；任何真实集成数恒为 0。

### 对象、引用与通信

AUTOSAR 路径作为完整对象身份，等宽、可选中、在详情自然换行，不使用 XML 行号。示例包含 ECUC 容器、signal、PDU、frame、interface、SWC、unknown 和 ECU 八个对象。

引用目标存在时跳转对应对象。缺失的 IF_Calibration 保持 unresolved，不擅自替换成名称相近的接口。unknown 作为诚实类别保留，不视为解析失败。通信关系仅展示模型链接，不声称满足实时性或供应商规则。

### 变更

示例参数：`CanControllerBaudRate`，初始值 500 kbit/s；编辑输入允许 1–1000 整数。这是原型输入约束，不是硬件有效范围承诺。

准备预览记录 before/after、配置 revision、environment 版本；预览不写入。应用前显式确认，并重新检查两个版本，拒绝过期上下文。应用递增配置 revision 并保存一次可撤销快照，所有既有证据继续归属原配置版本。

Undo 创建新 revision；不把旧通过结果重新解释为当前通过。应用和撤销更新 Objects、Changes、Workspace 和 Agent access 的同一份状态。输入变化取消旧预览，杜绝显示新值却应用旧预览。应用、撤销和绑定保存不会自动调用校验。

### 校验

供应商示例每次只执行一次，外部 agent 或用户决定后续操作。执行开始捕获工具名、版本、包、配置 revision、environment 版本与范围；完成时保留捕获上下文，禁止把其他版本误标为本次结果。

- Passed：请求范围内的示例检查完成，没有触发失败阈值；不证明范围外的检查或系统需求。
- Failed：执行产生了配置拒绝诊断。
- Partial：请求的检查覆盖未完成，不能作完整通过。
- Execution failed：没有有效校验结果，例如示例许可证失败；配置有效性未知。
- Stale：配置或环境版本变化。保留原结论及原始输出，但不当作当前证据。

结果可查看来源、包、版本、范围、阈值、诊断位置、原始输出和 JSON 导出。历史条目可选择查看，导出对应当前选中的记录。无记录时显示 Not run，不使用通过或零错误替代。

供应商配置诊断可定位到 ECUC 对象并进入变更。结构检查从独立 tab 显式执行，返回示例 unresolved finding，可定位 SWC 源对象。两者不合并 verdict；重复路径为 0 也不意味供应商接受。

运行和结构检查有进行状态；绑定与配置写入在执行过程中不可用。不同页面仍可以查看，完成后更新同一状态。

### Agent 接口

拟议接口：`capabilities.list`、`configuration.query`、`configuration.change`、`vendor.validate`、`vendor.generate`。并非已部署 API。

写操作和执行请求包含预期配置与环境版本，示例响应由当前共享状态推导。未执行生成时明确返回 not_run。不宣称产品已运行 MCP 服务，也不显示虚构工具数量或连接成功。

## 供应商目录

| 覆盖目标 | 本轮状态 | 必须保留的限制 |
|---|---|---|
| Vector DaVinci Configurator Classic | 示例就绪 | 只有模拟调用，非真实安装验证 |
| EB tresos Studio | 示例受阻 | 配置包和实际版本接口尚未确认 |
| ETAS ISOLAR | 未接入 | 不臆造现成 CLI |
| 普华 ORIENTAIS | Planned | 具体配置器版本、API/CLI 待核实 |
| 东软睿驰 NeuSAR Configurator | Planned | 具体版本、无人值守和报告格式待核实 |
| 经纬恒润 INTEWORK-EAS-CP 工具链 | Planned | 先确认实际配置产品及接口 |
| 睿赛德 AUTOSAR CP 配置工具 | Planned | 产品版本与自动化契约待核实 |
| dSPACE SystemDesk | Planned | 已有公开自动化 API/MCP；架构校验不等于任意 BSW 校验 |
| Siemens Capital Embedded Integrator AR Classic | Planned | 含 VSTAR 产品沿革，实际版本接口待核实 |
| KPIT KSAR C4K | Planned | 自动化接口与诊断导出待核实 |

目录共 10 个目标、4 个国产目标，不声称穷尽市场或全部支持。能力列表与可执行校验相互区分，不为候选伪造安装路径或已探测状态。

## 视觉契约

沿用现有家族中性色与 terracotta 品牌；未新增品牌方向。所有工作台入口共享 `shared.css`，主题通过 `data-theme` 切换，亮暗各有前景、背景、语义色与按钮文字定义。

值类 tokens 以当前 `prototype/shared.css` 为原型真源；对齐产品实现时映射家族 kit `site/family.css`，状态色与可读性修正按角色映射，不在文档复制另一份数值表。

字体角色：系统 UI 字体延续既有原型；路径与 JSON 使用系统等宽字体，无网络字体。正文、页面标题（宽/窄两档）、节标题、技术数据与辅助信息各成层级，间距按 4/8 倍数节奏，控件圆角与动效时长均见 `shared.css`；减少动态效果偏好下关闭动画。

accent 用于当前选择、链接和主操作；错误用 danger；缺失条件或过期证据用 warn；通过用 ok。颜色始终配文字。展示完整技术数据，不用大片装饰或不可操作的导航。

主区域采用 grid/flex 正常流；宽屏侧栏与双栏；窄屏顶部导航选择器，双栏/关系链重排单栏。没有为专业工具添加移动产品 roadmap。可响应窄窗口不表示已提供移动宿主。

## 可访问性与状态纪律

使用真实 button、label、input、select、dialog、details；所有操作有可见焦点。对话框支持取消和 Esc，并恢复触发控件或有效备用焦点。只在输入校验后显示错误，空表单不预先报错。

搜索与筛选由同一数据源计算；无匹配时给出明确空态。引用点击和诊断定位可键盘操作。`/` 聚焦当前搜索，Ctrl/Command + 逗号进入设置。

主题在所有工作台视图共享。状态优先存入浏览器 sessionStorage；宿主禁用时回退内存。同一标签内切换视图无须存储即可保持状态；刷新或跨文件入口能否保留取决于宿主的 storage 隔离策略，不保证跨设备持久化。

更新区域明确表示未连接版本与更新服务，不伪称检查成功或签名校验已发生。

## 平台与实现约束

本次只修改 OpenDesign 浏览器原型及其契约，不决定或改变实际产品技术线、宿主支持范围、仓库发布策略。供应商适配器的运行平台必须按已验证版本实际声明，不根据原型所在机器推导。

原型 JS 仅表达演示交互，不代表正式引擎实现；实际产品业务应依既定家族技术线放在引擎中。后续设计落账、实现对齐及发行另行进行，本轮不声称已 commit/push 或发布。

## 本轮完成边界与 Exit 条件

本轮交付覆盖八个主视图、既有七个 HTML 入口、统一主题/导航、配置变更与撤销、结构与供应商检查分离、证据过期与历史、工程绑定、国产覆盖目录及拟议 agent 契约。

关键界面和交互已写入可编辑源文件；用户评审、实际供应商接口验证和实现验收仍未完成，不代用户标记满意或设计冻结。本轮未执行额外截图、浏览器走查、测试或真实供应商运行，不将这些未发生的动作作为质量证据。

## 资料依据

- Vector 工程命令：https://help.vector.com/davinci-configurator-classic/en/latest/user-manual/references/cli/dvcfg-b/project.html
- Vector 校验范围与报告：https://help.vector.com/davinci-configurator-classic/en/latest/user-manual/references/cli/dvcfg-b/project-validate.html
- Vector AutomationInterface：https://help.vector.com/davinci-configurator-classic/en/latest/user-manual/base/using-the-tool/command-line-usage.html
- EB 功能说明：https://www.elektrobit.com/products/ecu/eb-tresos/studio/
- 普华生态资料：https://www.ti.com.cn/partner/cn/ISOFT
- NeuSAR：https://www.reachauto.com/neusar/ccore/
- INTEWORK：https://en.hirain.com/news/341.html
- 睿赛德：https://www.rt-thread.com/col26/list.html
- SystemDesk 官方仓：https://github.com/dspace-group/SystemDeskMCP
- Siemens：https://www.siemens.com/en-us/products/capital/ee-systems-embedded-software/
- KPIT：https://www.kpit.com/kpit-autosar-portal/

# Autarx

**面向 OEM-Tier1 集成数据的现代 AUTOSAR 工程工作台：检查、理解、比较、追溯、自动化。**
把 OEM 交付包或 ECU Extract 目录交给它，得到一个语义化工作区：对象清单、引用图、ECU 发现、未解析引用检查——全程可通过 agent 友好的 JSON CLI 脚本化。Autarx 位于厂商生成器**上层**；它不替代达芬奇、tresos 或 ISOLAR。

[![CI](https://github.com/turlamai/autarx/actions/workflows/ci.yml/badge.svg)](https://github.com/turlamai/autarx/actions/workflows/ci.yml) [![Release](https://img.shields.io/github/v/release/turlamai/autarx)](https://github.com/turlamai/autarx/releases/latest) ![Racket](https://img.shields.io/badge/Racket-CS-9F1D20?logo=racket&logoColor=white) [![License](https://img.shields.io/badge/License-Proprietary-red)](LICENSE)

**中文** · [English](README.md)

---

## 开始使用

工程预览；完整官方工作台规划为买断，目前尚未开放付费购买。 提供 macOS、Windows、Linux Rivet 桌面预览；CLI 和 MCP 共用 Racket 领域核心。AUTOSAR 支持范围由产品契约规定，不代表支持所有 ARXML。

[安装、首次使用、隐私与备份恢复](docs/USER-GUIDE.zh-CN.md) · [English](docs/USER-GUIDE.md)

## 为什么做 Autarx？

- **交付包是黑盒**——一个 OEM 交付是几十个 ARXML 文件：系统描述、ECU Extract、ECUC 捆绑混在一起；不打开完整厂商工具链，没人能回答"这里面有什么、它们拼不拼得起来"
- **ARXML 对 grep 不友好**——工程师在百万行 XML 树里手工翻找；把一个信号从 ECU 追回 Cluster，意味着跨文件人工解析几十个 REF 元素
- **没有自动化接口**——CI 无法 diff、追溯或体检交付包，因为没有厂商工具提供稳定的机器接口
- **Agent 帮不上忙**——LLM agent 依赖文本界面和结构化反馈，厂商工具两者皆无

Autarx 解决这些问题：一个无 UI 的语义引擎直接读取 ARXML，给人在 macOS、Windows、Linux 上的原生工作台，给脚本、CI 和 AI agent 一个 JSON 优先的 CLI。

## Autarx 是什么、不是什么

Autarx **可以**：读取 ARXML 工作区、以稳定绝对路径索引 identifiable、构建正/反向引用图、搜索、追溯、检查、输出确定性 JSON。

Autarx **不会**：替代达芬奇/tresos/ISOLAR、生成量产 BSW/RTE/MCAL 代码、宣称自己的校验能替代厂商校验。`validate` 只代表结构检查。产品链路是：**Autarx 分析 → 厂商工具 → 厂商校验 → 厂商生成器**。见 [docs/PRODUCT.md](docs/PRODUCT.md)。

## 功能

- **工作区语义索引**——每个包级 identifiable 获得稳定绝对路径（`/Vehicle/Signals/VehicleSpeed`）；身份绝不依赖 XML 行号
- **语义分类**——System、ECU、Cluster、Frame、PDU、Signal、SW 组件、Port、Interface、ECUC 模块；未知元素类型如实报告为 unknown，绝不导致解析失败
- **引用引擎**——基于 `*-REF`/`*-TREF` 的正反向图、跨文件解析、嵌套元素归因（`/Pdu_VehicleSpeed/VehicleSpeedMapping`）、重复路径检测、未解析引用发现
- **OEM 交付检查**——`inspect` 一次输出文件、大小、元素数、包数、AUTOSAR 命名空间/schema/release 和完整语义清单
- **ECU 发现**——`ecus` 列出 ECU 实例；`ecu <name>` 展示直接关系并显式标注 `direct` 关系置信度（不猜测语义）
- **语义 Diff**——`diff` 基于路径身份和内容哈希比较两版交付；属性级变化以 DEFINITION-REF 定位 ECUC 参数，"McuFrequency: 80000000 → 160000000" 是一等公民发现，而非行号噪声
- **ECU 影响分析**——`impact --ecu RadarFL` 通过两版交付引用图的并集闭包，把每个变化归类为"与本 ECU 相关/无关"；确定性 ARX-IMP-* 规则把"被引用对象被删""类型被改"判为 breaking
- **通信投影**——`comm` 从引用图推导 Cluster → Frame → PDU → Signal 链路，并报告未挂接的孤儿 Frame/PDU/Signal；只陈述结构，不虚构收发方向
- **厂商交接**——`vendor list` 探测达芬奇/tresos/ISOLAR 安装；`vendor validate` 中继厂商工具自身的运行结果（归一化诊断 + 保留原始输出）——这永远是厂商的结论，不是 Autarx 的
- **受控编辑**——`patch plan` 把每次修改先转成语义 diff 供审阅，未审阅不落盘；`patch apply` 保留备份和撤销清单；重命名会同步重写全工作区的入向引用
- **AI Agent 接口**——`autarx mcp` 启动 Model Context Protocol stdio 服务器暴露完整工具 API；不存在裸写文件工具，agent 无法绕过 plan/diff/审阅边界，且每次调用都进审计日志
- **在线自更新**——三平台宿主都通过 Ed25519 签名 feed 就地更新：macOS 工作台轮询 `update-app-manifest.json`，一次「重启并更新」即下载（带进度）→ 验签 → 换包 → 重启（`检查更新…`，⌘U）；Windows 便携版同样就地处换，MSI 安装走被动升级；Linux 工作台验签下载后以打开文件夹对话框交接（AppImage 原地替换并重启）。CLI 的 `autarx update` 检查自己的签名 feed（随每个版本发布的 Ed25519 签名 `update-manifest.json`），先验签再校验工件 SHA-256，就地替换二进制。未处理崩溃会在 `<TEMP>/autarx/crashes/` 留本地日志——不上传任何数据
- **Agent 友好 CLI**——camelCase JSON、确定性退出码、歧义显式上报而非猜测；现成的 CI 门禁命令链
- **三平台原生工作台**——macOS SwiftUI、Windows WinUI 3、Linux GTK4 壳跑在同一个嵌入式 Racket 核心之上，RPC 面与交互模型一致
- **单一核心二进制**——CLI 与 MCP 同体；每个 GUI 内嵌同一核心

## 命令行

```bash
# 检查整个 OEM 交付目录
autarx inspect ./OEM_Delivery/
autarx inspect ./OEM_Delivery/ --json

# 按 SHORT-NAME 子串搜索对象
autarx find VehicleSpeed ./OEM_Delivery/

# 谁引用谁
autarx refs VehicleSpeed ./OEM_Delivery/
autarx refs VehicleSpeed ./OEM_Delivery/ --incoming
autarx refs /Vehicle/Clusters/VehicleCan ./OEM_Delivery/ --outgoing --json

# 沿引用图追溯
autarx trace Pdu_VehicleSpeed ./OEM_Delivery/ --depth 3

# ECU 发现
autarx ecus ./OEM_Delivery/
autarx ecu ./OEM_Delivery/ Gateway --json

# 交付质量种子——存在发现时退出码为 1
autarx unresolved ./OEM_Delivery/

# 两版交付的语义 diff——有差异时退出码为 1
autarx diff ./V32/ ./V33/ --detail

# 我的 ECU 受了什么影响——有相关变化时退出码为 1
autarx impact ./V32/ ./V33/ --ecu RadarFL

# 通信链路与孤儿对象
autarx comm ./OEM_Delivery/ --cluster VehicleCan

# 厂商工具交接（探测 + 结果中继）
autarx vendor list
autarx vendor validate davinci ./Project.dvcfg

# 受控编辑：plan 只读预览，apply 保留备份，undo 撤销
autarx patch plan ./OEM_Delivery/ --file ops.json
autarx patch apply ./OEM_Delivery/ --file ops.json
autarx patch undo ./OEM_Delivery/

# AI agent 的 MCP stdio 服务器（JSON-RPC 2.0，带审计）
autarx mcp

# 自更新：检查并就地应用新版本
autarx update --check        # 只报告（有新版本时退出码 1）
autarx update                # 下载、校验 SHA-256、就地替换

# 单文件 ECUC 命令（仅结构校验——不是厂商校验）
autarx info Mcu.arxml
autarx modules Mcu.arxml --json
autarx validate Mcu.arxml
```

`autarx unresolved --json` 输出：

```json
[
  {
    "kind": "REQUIRED-INTERFACE-TREF",
    "sourcePath": "/Vehicle/SwCs/SpeedSensor",
    "sourceElementPath": "/Vehicle/SwCs/SpeedSensor/CalibrationIn",
    "targetPath": "/Vehicle/Interfaces/IF_Calibration",
    "sourceFile": "communication.arxml",
    "resolved": false
  }
]
```

## 安装

发布产物统一按 `autarx-<version>-<os>-<arch>.<ext>` 命名，从
[GitHub Releases](https://github.com/turlamai/autarx/releases) 下载：

| 下载 | 平台 | 形态 |
| --- | --- | --- |
| `autarx-<version>-macos-arm64.dmg` / `-x64.dmg` | macOS 14+，Apple silicon / Intel | GUI 工作台 |
| `autarx-<version>-windows-x64.msi` | Windows 10+（x64） | GUI 工作台 |
| `autarx-<version>-linux-amd64.deb` / `-arm64.deb` | Linux（x64 / arm64） | GUI 工作台 |
| `autarx-<version>-linux-*.rpm` | Linux（x64 / arm64） | GUI 工作台 |
| `autarx-<version>-linux-x86_64.AppImage` / `-aarch64.AppImage` | Linux（x64 / arm64） | GUI 工作台 |
| `autarx-<version>-linux-x64.flatpak` / `-arm64.flatpak` | Linux（x64 / arm64） | GUI 工作台（Flatpak bundle，app id `site.jrtx.autarx.Autarx`；`flatpak --user install ./autarx-<version>-linux-<arch>.flatpak` 安装） |
| `autarx-<version>-macos-arm64.zip` / `-x64.zip` | macOS（arm64 / x64） | CLI（自包含） |
| `autarx-<version>-linux-x64.zip` / `-arm64.zip` | Linux（x64 / arm64） | CLI（自包含） |
| `autarx-<version>-windows-x64.zip` | Windows（x64） | CLI（自包含） |

CLI zip 就是自更新的载荷：装好后 `autarx update` 会从签名验证的更新源拉取新版本。GUI 走签名的工作台 feed（`*-app.zip` / `*-app.tar.gz` 载荷随每个版本发布）就地更新。

> 发布二进制不带发行方代码签名：macOS DMG 为 ad-hoc 签名（未公证），Windows MSI 与 Linux deb / rpm / AppImage 未签名，因此 Gatekeeper 可能要求首次启动时显式放行（右键应用选「打开」），Windows SmartScreen 可能在首次运行 MSI 时告警。付费代码签名 / 公证仍是分发路线图上的剩余项（见 [docs/ROADMAP.md](docs/ROADMAP.md)）。

也可以从源码构建：

```bash
git clone https://github.com/turlamai/autarx.git
cd autarx
raco rivet build          # staged 应用 + CLI 运行时
racket racket/autarx/cli.rkt --version
```

前置：Racket CS 9.x 并 link [Rivet](https://github.com/turlamai/rivet)——完整路径见下方「快速开始」。

## 快速开始

### 从源码构建

依赖：Racket CS 9.x，并以 linked 方式装好 [Rivet](https://github.com/turlamai/rivet)
（在 rivet 检出内执行 `raco pkg install --auto --no-docs --name rivet --link file://$PWD`）。
macOS 宿主另需 Xcode；Windows 宿主需 Visual Studio 2022 + Windows App SDK；Linux 宿主需 CMake + GTK4（`libgtk-4-dev` 等）。`raco rivet build` 构建当前平台对应的宿主。

```bash
git clone https://github.com/turlamai/autarx.git
cd autarx
raco rivet build          # staged 布局：嵌入式后端 + 原生宿主
racket racket/autarx/cli.rkt inspect shared/fixtures/OemDelivery --json
raco rivet dev            # 开发循环：重建 + 启动工作台
```

### 测试

```bash
raco test racket/
```

131 项测试：101 项契约测试自 .NET 测试套件逐条移植，另加更新通道与工作台更新器测试，覆盖解析器（命名空间剥离、属性、错误行号）、语义分类、工作区索引、引用图、追溯、语义 diff、影响分析、通信投影、校验、补丁管线、厂商交接归一化、版本比较与两条更新面——基于 `shared/fixtures/` 下的同一套合成工作区（含刻意构造的未解析引用与歧义/重复路径）。

## 项目结构

```text
autarx/
├── rivet.rktd                  Rivet 应用清单
├── racket/
│   ├── autarx/                 # 语义引擎（Racket；无 UI 依赖）
│   │   ├── arxml.rkt           # 流式解析器 + 规范化写出
│   │   ├── index.rkt           # 工作区索引、引用图、trace、summary
│   │   ├── hash.rkt            # FNV-1a 内容哈希（跨实现契约）
│   │   ├── diff.rkt            # 语义 diff（路径身份 + 内容哈希）
│   │   ├── impact.rkt          # ECU 相关性闭包、ARX-IMP-* 规则
│   │   ├── comm.rkt            # Cluster→Frame→PDU→Signal 投影
│   │   ├── vendor.rkt          # 适配器探测 + 厂商交接中继
│   │   ├── patch.rkt           # plan/apply/undo、受控编辑
│   │   ├── update.rkt          # CLI 更新清单、SHA-256 校验、就地换装
│   │   ├── app-update.rkt      # 工作台更新器（后端 RPC 面）
│   │   ├── cli.rkt             # 工作区 + 单文件命令，--json
│   │   ├── mcp.rkt             # MCP stdio 服务器 + 工具注册表
│   │   └── backend.rkt         # Rivet RPC 面（GUI 宿主）
│   └── tests/                  # 契约测试 + 更新器测试 + RVT1 冒烟
├── macos-host/                 # SwiftUI 工作台
├── windows/                    # WinUI 3 工作台
├── linux/                      # GTK4 工作台
├── shared/fixtures/            # 合成交付包（ECUC 与非 ECUC）
├── docs/RIVET-MIGRATION.md     # R0–R8 重建计划与停止规则记录
├── docs/PRODUCT.md             # 定位、边界、非目标
└── ARCHITECTURE.md             # 架构决策
```

## 设计说明

- **Core 是语义引擎，不是 ECUC 解析器**——ECUC 只是投影之一；顶层模型（Workspace、SemanticObject、引用图）必须同样服务于系统描述和 ECU Extract
- **身份 = AUTOSAR 绝对路径**——跨改写稳定、为 diff 铺路；XML 行号绝不作为身份
- **Unknown 优雅降级**——未映射的元素类型照样索引、可引用、如实报告为 unknown，绝不是解析失败
- **歧义显式上报，绝不猜测**——重复 SHORT-NAME 返回明确的歧义结果并列出所有候选路径
- **CLI JSON 是机器契约**——camelCase 键、字符串枚举、确定性退出码、只做增量变更；脚本和 AI agent 依赖它

## 路线图

Rivet 重建（R0–R8）已完成：Racket 语义核心、字节兼容 JSON 的 CLI/MCP、原生 macOS 工作台，以及 R0 性能停止规则记录——见
[docs/RIVET-MIGRATION.md](docs/RIVET-MIGRATION.md)。工作台现已覆盖三大桌面（macOS / Windows / Linux）。项目处于 0.x 功能验证阶段；M9 剩余为商业化加固——授权、大型 OEM 交付上的性能画像、代码签名 / 公证（见 [docs/ROADMAP.md](docs/ROADMAP.md)）。

## 许可证

专有软件——© TuringLambdaAI，保留所有权利。见 [LICENSE](LICENSE)。

# AGENTS.md

## 家族设计（必读入口）

- 设计/UI 任务先加载 `tlai-product`，必读 `references/policy.md` 与 `references/design-standard.md`（理念、决策规则、UI 验收）。技能缺失时读取 ZCode 真源：macOS/Linux `~/Sync/ZCode/skills/tlai-product/`；Windows `D:/ZCode/skills/tlai-product/`。无法读取须报告规范未核验，不凭记忆跳过。
- 家族规范管共性；本仓现有设计、行为与 token 真源管具体值和产品差异。例外记回原契约，不复制家族规则或新增数值表；已有界面按下一次相关切片渐进对齐。
- 改界面先改原型、落账后实现；按家族 UI 清单与本仓当前技术线的既有门禁验收，原型对照和真实交互证据都要保留；对外宣传使用验收后的实物截图。

## 实现路由（agent 按任务读真源）

- 实现界面以 `design/prototype/` 为准：对照 HTML/CSS/JS 与实物截图验收，不依赖散文复述。
- Token/几何值真源 = `design/prototype/shared.css`（亮暗成对；无 shared.css 的仓 = design/prototype/ 各页样式）；`design/DESIGN.md` 只记语义名、用途与决策。
- 行为边界以 `design/DESIGN.md` 的不变式与平台差异节为准。
- 改界面先改原型再改实现（tlai-product）；动共享层（design/、shared/）先 issue 声明，同 commit 落契约。

## Current owner decision — 2026-11-18 quality-first

This is a **non-commercial development product**. The previous 2026-10 authorization, pricing, trial, Pro and Permit/Commerce rollout decisions are canceled. Do not implement or restore checkout, activation, subscription, paid feature gates, trial expiry or update-entitlement windows. Keep source licenses, release-signature verification, privacy protections and tested data migration intact. Focus only on real product functionality, native platform parity, recovery, clear bilingual READMEs and honest website status. Read the [current family policy](https://github.com/turlamai/turlamai.github.io/blob/master/PORTFOLIO.md) before every development slice.

Guidance for AI agents (and developers): how to understand, build, run and
change Autarx.

## What this is

Autarx is an AUTOSAR Integration Workbench (inspect, trace, diff and audit
OEM-to-supplier AUTOSAR delivery data), rebuilt on the Rivet application
framework: one Racket domain core (`racket/autarx/`), a JSON CLI + MCP
server linking the core directly, and native GUI hosts speaking RVT1.
`main` is the current Rivet development line. The archived .NET v1.0.3
implementation remains a historical behaviour/JSON reference in Git history;
do not develop against an old migration branch.

- Migration plan + stop-rule record: `docs/RIVET-MIGRATION.md`
- Product boundaries: `docs/PRODUCT.md`

## Platform scope (2026-11 reset — issue #56)

Autarx ships **Windows-only** across the board: workbench host, CLI
artifacts, CI matrix and release artifacts. Rationale: the vendor
toolchain Autarx accompanies (DaVinci, tresos, ISOLAR) runs only on
Windows, so macOS/Linux shipped to an audience that does not exist.
Version numbering restarted at 0.1.0; the multi-platform releases
v0.1.0–v0.5.0 and their tags were deleted. Consequences:

- The Racket engine stays host-agnostic: `raco test racket/` runs (and
  must stay green) on every dev machine; only `raco rivet build` (GUI
  host) is Windows. The updater's platform identity is a constant
  `windows`/`x64` pair.
- CI is windows-latest for tests/host/acceptance (plus the offline
  release-contract check); a release carries the Windows MSI, the
  portable app zip and the windows-x64 CLI zip.
- `windows/` remains the Windows machine's exclusive leg per family leg
  rules; macOS/Linux machines write the shared layer only.

## Quick commands

```bash
# 0) Prerequisite: Racket CS 9.x with rivet linked
cd ../rivet && raco pkg install --auto --no-docs --name rivet --link file://$PWD

# 1) Domain + contract tests (101 cases, RVT1 smoke included)
raco test racket/

# 2) CLI against a fixture
racket racket/autarx/cli.rkt inspect shared/fixtures/OemDelivery --json

# 3) Build the staged app (embedded backend + Windows WinUI host;
#    GUI host build is Windows-only — the engine/CLI/tests run anywhere)
raco rivet build
raco rivet dev

# 4) MCP server (newline-delimited JSON-RPC 2.0 on stdio)
racket racket/autarx/backend.rkt   # RVT1 transport (GUI/dev)
# mcp: racket racket/autarx/cli.rkt mcp

# 5) Large-file benchmark (R0 stop-rule reproduction)
racket scripts/gen-bench-ecuc.rkt -o "$TMPDIR/autarx-bench" -n 50000

# 6) Product acceptance on Windows (contract → RVT1 → native → package → UI)
raco rivet acceptance --json
```

## Contracts (read before changing behaviour; change both sides together)

- **CLI JSON**: camelCase keys in declaration order, null omitted, string
  enums, 2-space indent; exit codes 0/1/2/3 with per-command variants
  (diff: 0 identical/1 differs; vendor validate: 0 clean/1 tool failed/
  2 autarx-side; patch: 1 plan invalid). Byte-verified against v1.0.3.
- **Rule codes**: ARX001–ARX006 (validation) and ARX-IMP-\* (impact) are
  append-only, never renumbered.
- **Content hashes**: FNV-1a subtree hashes are a cross-implementation
  contract (UTF-16 code units, 2^64 wrap; see `hash.rkt`).
- **MCP**: 12 tools, indented payloads, compact error envelopes with
  explicit `"id":null`; every tools/call appends to
  `<workspace>/.autarx/audit.jsonl`.
- **Patch pipeline**: plan is read-only and produces a mandatory semantic
  diff; apply writes `.autarx/` backups + `patch-history.jsonl`; no raw
  write surface exists anywhere.
- **RPC surface** (`racket/autarx/backend.rkt` define-rpc): open/close
  workspace, summary, find/list objects, refs, trace, ecus, unresolved,
  diff, impact, communication, validate, patch plan/apply + `progress`
  event. Changing a signature requires regenerating host clients
  (`raco rivet build`).

## Layout

```
autarx/
├── rivet.rktd              Rivet manifest (backend/module/entry/protocol)
├── racket/autarx/          domain core + cli.rkt + mcp.rkt + backend.rkt
├── racket/tests/           101 contract tests + RVT1 smoke
├── windows/                WinUI 3 workbench (the shipped host; Windows machine's leg)
├── shared/fixtures/        synthetic deliveries (ECUC + System/Comm)
├── scripts/                bench generator
└── docs/                   RIVET-MIGRATION / PRODUCT / site
```

## Conventions

- Domain logic lives in `racket/autarx/` only; hosts render, CLI/MCP translate.
- Unknown AUTOSAR element types degrade to `unknown` — never a parse
  failure. Ambiguity is a first-class outcome, never silently resolved.
- Rivet framework gaps go upstream (issue/PR to turinglambdaai/rivet);
  this repo pins the reviewed `v0.12.0` release across CI, acceptance, and release.
- Agent 不得以单元测试、编译或截图单独宣称产品完成；涉及 GUI 的改动必须让
  `raco rivet acceptance --json` 在 Windows 通过，并保留原生控件交互与
  后端结果证据。
- `raco test racket/` must stay green on every change.

## 组合定位（Portfolio placement）

本产品目前是 **2026-11-18 质量与交付优先的非收费开发项目**。不重新引入旧版价格、购买、试用、Pro 或 Permit/Commerce 门禁；保持现行源码许可与更新签名安全。当前权威为 [产品组合策略](https://github.com/turlamai/turlamai.github.io/blob/master/PORTFOLIO.zh-CN.md)，不是已经删除的产品定价文件。

## 产品交付与下一步（2026-11-18）

先完成真实主流程、错误与恢复、原生平台体验、更新验签及完整中英文文档/产品主页验收。不要实施收费功能，不能用网页或单测代替发行包可用性证据。

## Documentation languages

Public default documentation is English; maintain complete Chinese user paths in `*.zh-CN.md`, with reciprocal links. Update both languages when prices, quotas, installation, recovery, privacy or supported platforms change. API/protocol identifiers and commands remain unchanged; do not maintain a second normative protocol or implementation. Follow the [family language policy](https://github.com/turlamai/turlamai.github.io/blob/master/docs/DOCUMENTATION-LANGUAGES.md). Existing internal notes are not a claim that every document is bilingual.

## Public product documentation

The paired `docs/USER-GUIDE.md` / `docs/USER-GUIDE.zh-CN.md` own the public installation, first-use, data/recovery, privacy and availability path. Keep the homepage and both README entry points aligned with them when behavior changes. Detailed technical contracts and the current implementation queue retain their existing owners. Do not publish target prices, a purchase link or a ready/secure/platform claim before its release evidence exists.

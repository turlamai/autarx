# AGENTS.md

## 实现路由（agent 按任务读真源）

- 实现界面以 `design/prototype/` 为准：对照 HTML/CSS/JS 与实物截图验收，不依赖散文复述。
- Token/几何值真源 = `design/prototype/shared.css`（亮暗成对；无 shared.css 的仓 = design/prototype/ 各页样式）；`design/DESIGN.md` 只记语义名、用途与决策。
- 行为边界与跨平台一致性以 `design/DESIGN.md` 的不变式与平台差异节为准。
- 改界面先改原型再改实现（tlai-prototype-flow）；动共享层（design/、shared/）先 issue 声明，同 commit 落契约。

## Authorization decision before implementation

Decision `2026-10-auth-1`: Offline perpetual entitlement plus a bounded update/feature window; no activation lease or device cap. Read the complete [local authorization decision](PRICING.md#authorization-decision-for-implementation) and its Chinese counterpart before commercial, trial, update-eligibility or credential work. Record this decision revision and the source/policy SHAs actually read in the PR/handoff. Refresh at each bounded slice; existing agent conversations do not receive this change automatically. Follow the existing product contract and implementation issue; do not activate a payment gate merely because a plan exists.

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

## Quick commands

```bash
# 0) Prerequisite: Racket CS 9.x with rivet linked
cd ../rivet && raco pkg install --auto --no-docs --name rivet --link file://$PWD

# 1) Domain + contract tests (101 cases, RVT1 smoke included)
raco test racket/

# 2) CLI against a fixture
racket racket/autarx/cli.rkt inspect shared/fixtures/OemDelivery --json

# 3) Build the staged app (embedded backend + macOS SwiftUI host)
raco rivet build
raco rivet dev

# 4) MCP server (newline-delimited JSON-RPC 2.0 on stdio)
racket racket/autarx/backend.rkt   # RVT1 transport (GUI/dev)
# mcp: racket racket/autarx/cli.rkt mcp

# 5) Large-file benchmark (R0 stop-rule reproduction)
racket scripts/gen-bench-ecuc.rkt -o "$TMPDIR/autarx-bench" -n 50000

# 6) Current-platform product acceptance (contract → RVT1 → native → package → UI)
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
├── macos-host/             SwiftUI workbench (SwiftPM; builds via rivet)
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
  `raco rivet acceptance --json` 在声明支持的平台通过，并保留原生控件交互与
  后端结果证据。
- `raco test racket/` must stay green on every change.

## 组合定位（Portfolio placement）

- 当前决策（2026-10-v2）：汽车配置工作台；完整官方版买断。具体价格、免费/付费边界和开卖门禁以本仓 [PRICING.md](PRICING.md) 为唯一权威；旧版收费候选与早鸟方案已被替代。
- 组合归属：[PORTFOLIO](https://github.com/turlamai/turlamai.github.io/blob/master/PORTFOLIO.md)。当前全部产品开发中、没有实际用户；目标定价不表示已经开卖，不因此立即给开发版加收费墙。
- 免费产品不接商业激活；付费层先实现可验证价值，再接 Commerce/Permit。优先完成本仓既有产品审查 issue；不修改现行源码 LICENSE。

## 产品交付与下一步（2026-10-23）

- 家族[交付标准](https://github.com/turlamai/turlamai.github.io/blob/master/docs/PRODUCT-STANDARD.md)与[组合策略](https://github.com/turlamai/turlamai.github.io/blob/master/PORTFOLIO.md)是共用政策；本仓具体行为以 `docs/ROADMAP.md` 为准，不复制五库依赖图。
- 当前执行入口：[产品审查 issue](https://github.com/turlamai/autarx/issues/22)。以 M9 为当前队列：先记录合成大型 ARXML 的索引/diff/影响分析性能预算与基线，再做 Permit 接入。历史栈只作历史说明，不再启动迁移分支。
- 开工先检查干净工作树与远端，以 fast-forward-only 更新并记录 SHA；共享文件一次一个写入者，保留其他 checkout 的未提交工作。
- 每次只完成一个可验收切片，记录 owned files、依赖 pin、命令/平台/产物证据和回滚。已实现、已发布、实机验收分别陈述；不修改 requirements 或复用旧证据来制造通过。

## Documentation languages

Public default documentation is English; maintain complete Chinese user paths in `*.zh-CN.md`, with reciprocal links. Update both languages when prices, quotas, installation, recovery, privacy or supported platforms change. API/protocol identifiers and commands remain unchanged; do not maintain a second normative protocol or implementation. Follow the [family language policy](https://github.com/turlamai/turlamai.github.io/blob/master/docs/DOCUMENTATION-LANGUAGES.md). Existing internal notes are not a claim that every document is bilingual.

## Public product documentation

The paired `docs/USER-GUIDE.md` / `docs/USER-GUIDE.zh-CN.md` own the public installation, first-use, data/recovery, privacy and availability path. Keep the homepage and both README entry points aligned with them when behavior changes. Detailed technical contracts and the current implementation queue retain their existing owners. Do not publish target prices, a purchase link or a ready/secure/platform claim before its release evidence exists.

## 设计流程（原型先行）

所有 UI 开发与界面改造一律先原型后代码：brief → `design/DESIGN.md`
视觉契约 → HTML 原型 → 按 HIG 基准评审通过才开工；改界面先改原型再改
代码。契约与原型放本仓 `design/`（尚未建立时随首个 UI 切片建立），
实物截图验收后才能作为对外宣传素材。

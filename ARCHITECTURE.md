# Architecture

## Positioning

Autarx is an **AUTOSAR Integration Workbench**: it inspects, explains,
compares, traces and automates OEM-to-supplier integration data. It sits
**above** the vendor generators (DaVinci / tresos / ISOLAR) — it does not
replace them and does not generate production BSW/RTE/MCAL code. See
[docs/PRODUCT.md](docs/PRODUCT.md) for the full boundary.

## Pipeline

```text
Raw ARXML
    ↓
Workspace
    ├── Documents          (per-file metadata, schema/release info)
    ├── Identifiables      (stable absolute paths)
    ├── References         (forward graph)
    ├── Reverse References (incoming graph)
    ├── Provenance         (source file per object/reference)
    └── Diagnostics        (unresolved, duplicates, file errors)
            ↓
Semantic Projections
    ├── System / ECU / Communication / SWC
    └── ECUC  ← one projection among several, never the top model
            ↓
Query · Trace · Diff · Impact · Validation
            ↓
CLI · GUI · CI · AI
```

## Stack

Racket CS 9 for the semantic engine and agent surfaces (CLI + MCP), Rivet
for the GUI transport, WinUI 3 for the Windows workbench. Autarx ships
Windows-only — it sits next to the Windows-only vendor toolchain — while
the Racket engine stays host-agnostic. One UI-free core,
two frontends — the .NET/Avalonia implementation (v1.0.3) served as the
behaviour and JSON oracle for the rebuild; see
[docs/RIVET-MIGRATION.md](docs/RIVET-MIGRATION.md) for the migration
record, including the R0 performance stop-rule result (Racket indexes a
1.2M-line ECUC workspace in ~2.5× the .NET time, well inside the 5×
budget).

- **One core, two frontends.** The CLI/MCP link the domain core directly;
  GUI hosts speak RVT1 over Rivet.
- **The CLI JSON is byte-compatible with v1.0.3** — camelCase keys in
  declaration order, null-omitted, string enums, exit codes 0/1/2/3 —
  verified by byte-level diffing against the .NET CLI during the rebuild.
- **Content hashes are a cross-implementation contract** — the FNV-1a
  subtree hashes match the .NET values, so diffs remain stable across the
  implementation boundary.

## Layering

```text
racket/autarx
   ├── arxml.rkt      streaming parser, canonical writer
   ├── index.rkt      WorkspaceIndex builder/queries/trace/summary
   ├── diff.rkt       semantic diff + property explanations
   ├── impact.rkt     ECU closure, ARX-IMP-* findings
   ├── comm.rkt       communication projection
   ├── vendor.rkt     adapters + hand-off relay
   ├── patch.rkt      plan/apply/undo
   ├── cli.rkt        workspace + single-file commands, --json
   ├── mcp.rkt        MCP stdio server
   └── backend.rkt    Rivet RPC surface for GUI hosts
```

Nothing outside Core re-parses ARXML. ViewModels and CLI commands hold no
AUTOSAR domain logic.

## Semantic model

- **Identity is the AUTOSAR absolute short-name path**
  (`/Vehicle/Signals/VehicleSpeed`) — stable across file rewrites. XML line
  numbers are never used as identity.
- `SemanticObject` = ShortName, ElementType, SemanticKind, AbsolutePath,
  SourceFile. Only package-level ELEMENTS children are indexed as objects;
  nested identifiables (ports, mappings, connectors) appear through reference
  attribution chains and semantic counts.
- `SemanticKind` classification is deliberately partial: exact names for the
  types every delivery contains, suffix rules for open families
  (`*-PDU`/`*-SDU`, `*-INTERFACE`, `*-PORT-PROTOTYPE`,
  `*-SW-COMPONENT-TYPE`), and `Unknown` for everything else. **Unknown never
  fails parsing** — new AUTOSAR model elements degrade gracefully.
- Duplicate absolute paths are recorded, never silently merged; path lookup
  deterministically resolves to the first occurrence (files in sorted order).

## Reference engine

- Captured from `*-REF` / `*-TREF` elements whose text is an absolute path.
- **DEFINITION-REF is excluded**: it points at module definitions that
  typically live outside the delivery and would flood the unresolved report
  with non-findings.
- References are attributed to the owning package-level object
  (`SourcePath`) plus the nested SHORT-NAME chain
  (`SourceElementPath`, e.g. `/Vehicle/Pdus/Pdu_VehicleSpeed/VehicleSpeedMapping`).
- Resolution is workspace-wide and cross-file; the reverse graph is derived,
  not maintained separately.
- `Unresolved` = target path absent from the workspace. This is the seed of
  the future OEM delivery quality check — it is a *finding*, not an error.

## Trace

Generic breadth-first graph walk (`WorkspaceIndex.Trace`) with direction
(outgoing/incoming/both) and depth limit. Communication semantics
(Signal → PDU → Frame → Cluster → ECU) layer on top of this API through the
communication projection — nothing is hardcoded into the CLI.

## Semantic diff

the semantic diff (`diff.rkt`) compares two workspaces by **path identity**. Modified
detection uses FNV-1a content hashes captured per object at index time, so
"did anything change" needs nothing beyond the two indexes. Property-level
explanations re-read the affected source files on demand and compare subtrees
with SHORT-NAME / DEFINITION-REF sibling keying (occurrence-suffixed when
repeated) — ECUC parameter changes are reported as
`…/DiagParamA/VALUE: 1 → 2`, never as line numbers. Reference changes are
diffed by semantic identity (source, kind, target): a reference moving
between files is not a change.

## Impact analysis

the impact analysis (`impact.rkt`) seeds a breadth-first closure at the ECU instance
over the **union** reference graph of both deliveries, then classifies every
diff entry relevant/unrelated. Findings carry stable rule ids (ARX-IMP-*,
append only): removed-referenced, type-changed and ECU-touching
reference-removals are breaking; additions, retargets and property changes
are informational. Communication impact counts relevant changes among
clusters/frames/PDUs/signals.

## Communication projection

the communication projection (`comm.rkt`) derives chains purely from the
reference graph: ECU connectors (`*CHANNEL-REF`), frame triggerings nested
under clusters (attributed to the cluster), PDU-to-frame mapping objects
(holding both `*FRAME-REF` and `*PDU-REF`), signal-to-PDU mappings nested
inside PDUs. Objects attached to nothing are reported as orphans. Direction
(sender/receiver) is deliberately **not claimed** — the structural graph
does not carry it reliably.

## Vendor hand-off

the vendor adapters detect DaVinci / EB tresos / ISOLAR through HOME env vars and
PATH (probes injected for testability) and runs a **hand-off**: the vendor
tool executes, Autarx normalizes its output (loose error/warning line
heuristic) and preserves the raw output under `.autarx/`. The report relays
the vendor's own result — never an Autarx verdict — and no generation is
reimplemented.

## Reviewed patching

the patch engine (`patch.rkt`) is plan → apply → undo. Planning runs operations against
in-memory trees, materializes the full patched workspace into a temp
directory and computes the mandatory before/after **semantic diff** —
nothing is written. Apply writes only files the diff proved changed, keeps
`.autarx/` backups plus a `patch-history.jsonl` manifest for undo, and adds
a provenance comment. Renames rewrite incoming reference targets across all
workspace files. `Parsing/ArxmlWriter` emits canonical serialization
(deterministic indent, sorted attributes, root namespace reconstruction) —
semantically equivalent, deliberately not byte-faithful.

## Self-update

Two deliverables, two update channels (the contract is
`shared/spec/UPDATE.md`):

**Workbench (Windows).** The backend updater (`app-update.rkt`) fetches
the signed workbench feed `update-app-manifest.json` — the family wrapper
format (rivet/distribution): base64 inner manifest + Ed25519 signature
over its exact bytes, verified against the embedded key. The artifact is
sha256-checked during download, and the install flavor follows the
running install: a copy under Program Files takes the sibling signed
`.msi` and the host hands off to a passive msiexec upgrade; portable
installs swap the install directory. A silent check runs shortly after
launch, throttled to one attempt per 4 hours (stamp under
`%LOCALAPPDATA%\autarx`); the menu entry "Check for Updates…" (Ctrl+U)
bypasses the throttle. The release publish job signs the manifest with
the `UPDATE_ED25519_PRIVATE_KEY_B64` secret.

**CLI.** the updater (`update.rkt` + the `update` command in `cli.rkt`)
rides `rivet/distribution` since 0.4.1: fetch the Ed25519-signed feed
`update-manifest.json` (the family wrapper format — base64 inner manifest +
signature over its exact bytes, verified with the embedded `autarx-2026-10`
key before a byte of it is parsed), select the artifact for this
platform × architecture (channel, version, rollout bucket), and download
it under the signed size + sha256 enforcement. Neither leg can hang: a
60 s manifest deadline and a 120 s stall / 30 min wall-clock download
watchdog. `--feed` overrides the manifest URL (HTTPS only — the local-file
path went with the checksum channel). The install leg is CLI-owned:
re-verify the zip checksum, unpack, locate the marker executable, and swap
files in place — current files move to `<name>.autarx-update.old` (allowed
while the executable runs on Windows), stale backups are cleaned on the
next update. The publish job signs the feed with the
`UPDATE_ED25519_PRIVATE_KEY_B64` secret, fail-closed: no key, no release.
Builds up to 0.4.0 read the retired plaintext checksum shape (and its
`latest.json` alias) and report a failed check against the signed feed;
they need a one-off manual install to cross over. The version is never
embedded in the updater — it stays single-sourced in rivet.rktd /
rivet-app-info.rktd and is passed in by the CLI.

Unhandled exceptions write a local crash log under `<TEMP>/autarx/crashes/`
and exit 3 — nothing is sent anywhere.

## AI layer (MCP)

the MCP server (`mcp.rkt`) is a newline-delimited JSON-RPC 2.0 stdio server exposing
the full tool API (inspect/find/refs/trace/ecus/unresolved/diff/impact/
comm/validate/patch_plan/patch_apply). The review boundary is structural:
no raw-write tool exists, both patch tools run the plan/diff gate, and every
tools/call is appended to `<workspace>/.autarx/audit.jsonl`.

## Diagnostics (structural validation)

Structural validation reports SHORT-NAME paths over the **ECUC projection**.
Rule codes are part of the CLI contract. **Never renumber; append only.**

| Code   | Severity | Rule |
| :----- | :------- | :--- |
| ARX001 | Error    | Module configuration missing DEFINITION-REF |
| ARX002 | Error    | Container missing DEFINITION-REF |
| ARX003 | Error    | Duplicate sibling container SHORT-NAME |
| ARX004 | Error    | Parameter has neither VALUE nor VALUE-REF |
| ARX005 | Warning  | Parameter DEFINITION-REF outside module definition |
| ARX006 | Error    | Module/container missing SHORT-NAME |

**Scope wording:** `validate` covers XML correctness, workspace integrity,
broken references, duplicate paths and structural rules only. It is *not*
vendor validation and must never be presented as "AUTOSAR compliant" or
"production valid". Vendor validation arrives later as explicit adapters
(`autarx vendor validate`).

## CLI JSON contract

- `--json` emits camelCase keys, indented; enums serialize as camelCase
  strings (`"communicationCluster"`), never integers.
- Exit codes: `0` success · `1` nothing matched (find/refs/trace/ecu) or
  findings reported (validate/unresolved/diff/impact) · `2` usage/file/parse
  error or ambiguous object name · `3` unhandled crash (local crash log
  written). Deterministic, documented in `--help`.
  Per-command variants: diff `0` identical/`1` differences; impact `0` no
  relevant changes/`1` relevant changes; patch `1` plan failures with
  nothing written; vendor validate `0` tool clean/`1` tool reported
  failure/`2` autarx-side problem (unknown tool, not detected, timeout).
- Ambiguity is a first-class outcome: a SHORT-NAME matching several objects
  exits 2 and lists the candidate paths — never a silent guess.
- Additive changes only — scripts, CI and AI agents parse this output.

## Testing

Parser, ECUC, classification, workspace index, reference graph, summary,
trace, diff, impact, communication projection, vendor hand-off
normalization, patch plan/apply/undo round trips and the MCP protocol run
against checked-in fixtures — including a synthetic non-ECUC
System/Communication workspace (`Fixtures/OemDelivery`, with deliberate
unresolved references and duplicate/ambiguous-path fixtures) and the
`DiffBefore`/`DiffAfter` delivery pair. CI builds, tests, and smoke-runs
every command's exit-code contract on every push.

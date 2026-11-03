# Changelog

All notable changes to autarx are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- Keep each `main` commit's CI run independent, including while GitHub-hosted
  runners are queued; cancel only superseded PR attempts. Test matrix and
  release trust-root checks remain unchanged.
- "Check for Updates…" moved into the App menu directly below About on
  macOS (About itself moves out of the Help menu to join it), per the
  family menu convention. Windows and Linux already had the Help-menu
  pair.

## [0.5.0] - 2026-10-15

The all-desktops release: the workbench ships natively on Windows and
Linux, joining the macOS host over the same embedded Racket core, RPC
surface and interaction model (taskly is the family benchmark: WinUI 3
over rivet's Windows platform layer, GTK4 over the Linux one).

### Added

- **Windows workbench (`windows/`, WinUI 3)** — the five-section semantic
  workspace (Workspace summary, Objects, ECUs, Unresolved references,
  Communication), the references inspector, progress events, open-delivery
  folder/file pickers, an About panel and the family update flow. Built by
  `raco rivet build` through the same `RivetHost.vcxproj` shape the family
  hosts use; CI compiles it on `windows-latest`.
- **Linux workbench (`linux/`, GTK4)** — the same interaction surface with
  GNOME light/dark theme following the desktop color scheme; CI compiles it
  on Ubuntu and boots it headless under Xvfb.
- **The workbench update flow now covers all three hosts.** The backend
  grows `check_updates` / `start_download` / `update_state` (the taskly
  family shape) on a new `app-update.rkt` updater: it fetches and verifies
  the signed workbench feed, downloads with progress under stall/total
  watchdog bounds, and reports the verified artifact — Windows portable
  installs swap the install directory in place, MSI installs run a passive
  upgrade, Linux portable copies get an open-folder hand-off, AppImage
  installs swap the image in place and re-exec, deb / rpm installs get
  package-manager guidance. The macOS host keeps its RivetUpdate client
  (the same feed). The 4-hour silent-check throttle is host-side on every
  platform.
- **Release artifacts for the two new hosts**: the Windows workbench ships
  as `autarx-<version>-windows-x64.msi` plus a portable zip, the Linux
  workbench as `.deb` / `.rpm` / `.AppImage` (x64 and arm64) plus a
  `tar.gz`; the human installers keep the plain family names while the
  update payloads carry the family `-app` suffix. Stable versionless
  aliases now cover every platform's primary installer.

### Changed

- **The workbench feed (`update-app-manifest.json`) carries all three
  platforms** — five artifacts: macOS arm64/x64 app zips, the Windows x64
  app zip and the Linux x64/arm64 app tarballs. One feed, one key, one
  format; the CLI feed (`update-manifest.json`) is unchanged.
- The README install table, project structure, roadmap and the product
  site describe the three-platform delivery; the release notes template
  does the same.

## [0.4.3] - 2026-10-15

The pin-restore release. The headline is a release-pipeline repair, not a
product change — the foundation round below (feedback surfaces, no domain
behaviour change) rides along in the same rebuild.

### Fixed

- **The release pipeline builds against the pinned rivet again.**
  `release.yml` referenced `env.RIVET_PIN` without ever defining it: the
  empty ref made `raco pkg install 'URL#'` silently resolve to rivet
  main-HEAD, so the v0.4.1 / v0.4.2 release artifacts were built from
  untested upstream commits while the contract tests ran the pinned
  v0.11.0 — the Windows and Linux CLI zips, the payloads `autarx update`
  distributes on those platforms, shipped this way. The pin is now defined
  once at workflow level (the same single source as `ci.yml`), and
  **0.4.3 is the first release off the restored pinned build chain**: the
  same product rebuilt on rivet v0.11.0, with no domain-code change
  involved.

### Added

- **Help ▸ About** (macOS workbench): an About panel carrying the
  `Autarx v<version>` line (bundle version, falling back to the generated
  Rivet config), the product site (autarx.jrtx.site), a Report-an-Issue
  link to the GitHub tracker and the license line — "Proprietary — all
  rights reserved", matching the LICENSE, with no opensource link
  promised.
- **GitHub issue templates** (bug report + feature request) so feedback
  from the About link lands structured: the bug form asks which surface
  (GUI / CLI / MCP), the delivery shape and the ARX rule codes involved.

### Changed

- **Update failure text is selectable** in the update panel's failed
  state, so the exact error — URLs, manifest verification failures — can
  be copied into a bug report instead of retyped.
- **ARCHITECTURE.md tells the signed-wrapper story** — the update-chain
  description no longer narrates the retired plaintext checksum feed.
- **The package declares its `crypto` dependency and carries no version
  literal**: rivet.rktd stays the single version source (the `info.rkt`
  package version that could float free of the product is gone), and the
  updater's Ed25519 surface is an explicit catalog dependency.

## [0.4.2] - 2026-10-14

The legacy plaintext update feed is retired for good: with no installed
base to carry over, the README and site stop carrying the dual-feed
crossover story — only the signed `update-manifest.json` /
`update-app-manifest.json` remain.

## [0.4.1] - 2026-10-14

Supply-chain alignment release: the signed update feed goes live, and the
release pipeline can no longer publish without it.

> **Attention CLI users — one-off manual update required.** Starting with
> 0.4.1, `update-manifest.json` is an Ed25519 signed wrapper. Every CLI
> build up to and including 0.4.0 reads the legacy plaintext checksum
> shape, so its **first `autarx update` against 0.4.1 or later fails
> closed** with a verification error instead of updating. To cross over,
> download the zip for your platform from the
> [0.4.1 release page](https://github.com/turinglambdaai/autarx/releases/tag/v0.4.1)
> once and replace the existing binary (verify against the `.sha256`
> sidecar). From 0.4.1 on, `autarx update` works unattended again. The
> macOS workbench is unaffected — its in-app updater already verifies the
> signed `update-app-manifest.json`.

### Changed

- **The update chain is authenticated end to end.** The CLI updater
  (`autarx update`) was rewritten onto `rivet/distribution`: it now
  fetches and verifies the Ed25519-signed channel manifest
  (`fetch-update-manifest`), selects the artifact for the running
  platform (`select-update`, sticky `crypto-random-bytes` rollout
  bucket), and downloads under size + SHA-256 enforcement from the
  signed manifest (`download-update`). This retires the curl subprocess,
  the hand-written FIPS 180-4 SHA-256, and the unauthenticated
  checksum feed — the supply-chain gap flagged in the family audit.
  The release pipeline signs `update-manifest.json` with the same
  `autarx-2026-10` key as the workbench feed; a missing signing key now
  fails the release instead of shipping an unsigned feed, and the
  `latest.json` alias is retired. Both network legs gained watchdog
  timeouts (60 s manifest, 120 s stall / 30 min download).
  **This is the first release that publishes the signed wrapper** — the
  0.4.0 feed was still the plaintext checksum document, which is why the
  manual crossover above covers every build up to and including 0.4.0
  (shared/spec/UPDATE.md).
- **The macOS workbench update client is rivet's shared `RivetUpdate`
  module** (since rivet 0.8.1): signed-manifest verification, the bounded
  download, sha256/size enforcement, the ditto unpack + version
  confirmation, the atomic swap with rollback, and the quit/relaunch
  handoff moved into the library; `UpdateService.swift` shrank to a thin
  product adapter (feed, key, key id, bundle name, error mapping).
- **The workbench feed is fail-closed in the release pipeline too** — a
  missing `UPDATE_ED25519_PRIVATE_KEY_B64` now fails the publish job
  with an error instead of uploading the release without
  `update-app-manifest.json` (the CLI track already behaved this way).
- CI installs rivet from the pinned tag (`v0.11.0`) instead of the
  moving catalog head; `macos-host/Package.swift` consumes rivet's root
  package (`.package(path: rivetRoot)`, product package name `rivet`),
  matching the family shape.
- **Website** (docs/index.html): the hardcoded "v0.1.0 · M0–M8" version
  strings are gone — the milestone/status copy states the product stage
  without a version literal that rots; default language is now Chinese
  (`lang="zh-CN"`, English stays one click away); the palette moves to
  the family tokens (warm paper `#faf7f2` background, terracotta
  `#c15f3c` accent); a dark theme ships with a toggle, `localStorage`
  persistence and a no-flash head script.
- **User guide** (docs/guide.html): a command handbook for the CLI —
  five-minute start, every subcommand with a real example and its flags,
  a short GUI section and an FAQ (platforms, license data, coexistence
  with DaVinci/tresos, update mechanics, uninstall). Bilingual, default
  Chinese, linked from the site navigation.

## [0.4.0] - 2026-10-12

Real-delivery hardening release: every fix below was driven by running the
workbench against genuine OEM deliveries (hundreds of ARXML files, up to
322 MB) for the first time.

### Fixed

- **ECUC container values are identifiables** — nested
  `ECUC-CONTAINER-VALUE` elements are indexed with their absolute paths and
  take over reference attribution, so the `VALUE-REF`s that point at them
  resolve inside a single ECUC file. On a real 97 MB DaVinci ECUC this
  turns 49,068 unresolved references into 21,374 (the remainder are
  genuinely cross-file); the container count (45,186) matches the file's
  XML exactly
- **XSD revision numbers map to releases** — vendor files carrying
  `AUTOSAR_00044.xsd`-style schema locations reported the raw revision;
  known revisions now translate to the classic version (00043 → 4.3.0,
  00044 → 4.3.1, 00047 → 4.4.0, 00048 → 4.5.0, 00049 → 4.6.0,
  00050 → 4.7.0), unknown ones stay raw rather than guessing
- **Constants classify** — `CONSTANT-SPECIFICATION` elements report as the
  new `constant` semantic kind instead of `unknown` (539/539 classified on
  a real 322 MB constants delivery)
- **ECU membership recovered through NM config** — DaVinci-style system
  extracts carry no direct ECU↔cluster edge: the NM-CLUSTER holds the
  `COMMUNICATION-CLUSTER-REF` and each NM-NODE a controller ref into the
  ECU. The communication projection pairs the two by nested element-path
  prefix and rides the controller target back to its owning ECU, so real
  clusters list their ECUs (verified: 5/5 clusters on a real extract)
- `I-SIGNAL-I-GROUP` classifies as `signal` (the table carried a
  misspelled `I-SIGNAL-GROUP` that never matched)

### Changed

- Semantic kinds are append-only: `ecuc-container` and `constant` join the
  inventory, the CLI/JSON contracts and the GUI inventory rows

## [0.3.0] - 2026-10-12

In-app update release: the macOS workbench now updates itself through
the family's signed-feed updater, and the host moves to the current
Rivet generator line.

### Added

- Workbench in-app updater (`shared/spec/UPDATE.md`): a silent check
  shortly after launch (throttled to one attempt per 4 hours) plus a
  manual `Check for Updates…` (⌘U) menu entry. The offer panel
  downloads a portable app zip with progress, verifies the Ed25519
  manifest signature, the artifact checksum and the unpacked bundle
  version, swaps the bundle in place and relaunches — only copies under
  `/Applications` (or `~/Applications`) can self-update
- Signed workbench feed `update-app-manifest.json`: the release publish
  job generates and signs it (`rivet/distribution` wrapper format, key
  id `autarx-2026-10`, secret `UPDATE_ED25519_PRIVATE_KEY_B64`) and
  re-verifies the signature before the release ships; a missing secret
  publishes a warning and no manifest rather than an unsigned one
- Portable app zips `autarx-<version>-macos-<arch>-app.zip` — the
  updater's payload, beside the human-installer DMGs, with the usual
  `.sha256` sidecars

### Changed

- Rivet pin 2fcdd09 → 53487b3: generated Swift DTOs moved into the
  `RivetTypes` namespace (upstream #174); the host is migrated and back
  on the current generator line. The CLI feed (`update-manifest.json`
  + `latest.json` alias) is untouched — CLI builds up to 0.2.0 keep
  updating through their checksum channel

## [0.2.0] - 2026-10-11

Packaging-parity release: the asset set closes every gap that does not
require the still-in-development Windows and Linux GUI hosts.

### Added

- The macOS workbench ships an Intel build: `autarx-<version>-macos-x64.dmg`
  joins the Apple-silicon DMG (native per-arch Racket, no Rosetta)
- CLI zips for `macos-x64` and `linux-arm64` — the CLI now covers
  `{macos-arm64, macos-x64, linux-x64, linux-arm64, windows-x64}`, built on
  native per-arch runners
- Every release asset ships a per-asset `.sha256` sidecar beside the
  aggregated `SHA256SUMS`

### Changed

- The update feed is published as `update-manifest.json` (family
  convention) and carries the two new CLI platforms; a byte-identical
  `latest.json` rides along so pre-0.2.0 CLI builds keep self-updating —
  the alias will be dropped once the field has moved on

## [0.1.0] - 2026-10-10

Version epoch reset. The technical rewrite is settled, so the project enters
a 0.x functional-validation phase: the first release of the new epoch is
0.1.0. The 1.x-era releases and tags (v1.0.0, v1.1.0 of the Rivet rebuild)
were deleted from GitHub Releases and the tag list; the sections below stay
as the historical record of that era.

### Changed

- Release artifacts follow `autarx-<version>-<os>-<arch>.<ext>` (lowercase,
  with architecture): `autarx-0.1.0-macos-arm64.dmg` for the macOS
  workbench and `autarx-0.1.0-{macos-arm64,linux-x64,windows-x64}.zip` for
  the CLI. The old `Autarx-*-macos.dmg` and `autarx-cli-*` names are gone;
  the update-feed contract and release workflow were updated to match.
- The version is single-sourced on `rivet.rktd`. The CLI no longer carries
  a version literal — source checkouts read the repo manifest, distributed
  builds read `rivet-app-info.rktd`; a build that finds neither fails
  instead of reporting a stale version. `scripts/check-release-version.sh`
  (release-gate, taskly-style) enforces tag == rivet.rktd ==
  GeneratedBackend.swift and that the CHANGELOG announces the release.
- The rivet generator is pinned in CI/release workflows (the RivetTypes
  namespace change in rivet breaks this SwiftUI host until it is adopted).

## 1.1.0 - 2026-10-09

### Added

- **Self-updating CLI**: `autarx update` now has a live feed. Releases ship
  self-contained CLI zips (launcher + embedded Racket runtime) for macOS
  (arm64), Linux (x64) and Windows (x64), and a checksum-verified
  `latest.json` feed; check compares versions, apply downloads, verifies
  SHA-256 before touching anything, and swaps in place with
  `.autarx-update.old` backups. The feed is the contract documented in
  `racket/autarx/update.rkt`; the GUI leg stays manual (DMG drag-install)
  until the Windows/Linux hosts land.
- The CLI reports its true version: distributed builds carry
  `rivet-app-info.rktd` beside the launcher and read it at startup
  (source checkouts fall back to the rivet.rktd literal). The shipped 1.0.0
  launcher reported a stale internal constant.

### Fixed

- `autarx update` extraction works on Windows (PowerShell
  `Expand-Archive`) instead of assuming `unzip`.

## 1.0.0 - 2026-10-08

First release of the Rivet rebuild: the semantic engine, CLI, MCP server and
the native macOS workbench are one Racket codebase. Ships macOS (Apple
silicon, macOS 14+); the Windows and Linux hosts are in development.

### Added

- One Racket codebase replacing the .NET/Avalonia implementation (v1.0.3,
  archived as the behaviour oracle): JSON output, exit codes, rule codes and
  content hashes are contract-compatible — verified byte-level against the
  v1.0.3 CLI and by 101 ported contract tests. Indexing on a 1.2M-line ECUC
  workspace is ~2.5× the .NET baseline (R0 stop-rule passed).
- `autarx mcp` unchanged (12 tools, audit logging); CLI unchanged
- Native macOS workbench (SwiftUI) over the embedded Racket core via RVT1
- `progress` RPC event during long indexing/diff operations
- In-place self-update (`autarx update`): checksum-verified feed, previous
  binaries kept as `.autarx-update.old`

### Removed

- .NET/Avalonia implementation tree (`src/`, `tests/`, `Autarx.slnx`)


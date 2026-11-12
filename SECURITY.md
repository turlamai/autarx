# Security Policy

Autarx keeps your engineering data on your machine: AUTOSAR deliveries are
parsed and analyzed locally, the patch pipeline writes only inside the
workspace (`.autarx/`, plus `<file>.autarx-bak` backups next to the edited
files), and crash logs stay under `<TEMP>/autarx/crashes/`. The only network
traffic is checking and downloading updates against GitHub Releases — there
is no telemetry, no account, and no listening port. Reports are taken
seriously and handled quickly.

## Reporting a vulnerability

Email **security@jrtx.site** (or open a GitHub security advisory on this
repository). Include reproduction steps, affected versions, and your
assessment of impact. You will get an acknowledgment within 72 hours.

Please do not open public issues for security problems.

## Scope

In scope:

- Update trust: verification of the two Ed25519-signed release feeds — the
  CLI channel's `update-manifest.json` and the workbench channel's
  `update-app-manifest.json` — plus key handling and rotation
  (`racket/autarx/update.rkt`, `racket/autarx/app-update.rkt`,
  `macos-host/Sources/RivetHost/UpdateService.swift`,
  `scripts/update-keys.sh`, `scripts/make-update-manifest.sh`,
  `scripts/make-update-feed.rkt`, `scripts/check-update-signing-key.py`;
  key id `autarx-2026-10`)
- AUTOSAR data parsing and the reference graph: everything Autarx concludes
  from an untrusted OEM delivery (`racket/autarx/arxml.rkt`,
  `racket/autarx/classify.rkt`, `racket/autarx/index.rkt`,
  `racket/autarx/diff.rkt`, `racket/autarx/impact.rkt`). A malformed file
  must fail with an honest diagnostic, never corrupt the workspace or crash
  the backend into a bad write
- The reviewed-editing pipeline: plan/apply/undo (`racket/autarx/patch.rkt`)
  — writes stay inside the workspace, every apply keeps `.autarx-bak`
  backups and appends to `.autarx/patch-history.jsonl`, and undo must only
  ever restore what apply changed
- Vendor hand-off: detection and relayed validation
  (`racket/autarx/vendor.rkt`). Relay results are the vendor tool's own
  conclusions passed through with the raw output preserved — anything that
  invents, filters or rewrites a vendor verdict is a bug
- The MCP stdio server (`racket/autarx/mcp.rkt`): JSON-RPC 2.0 over stdio
  with every call appended to `<workspace>/.autarx/audit.jsonl`; it must
  stay stdio-only and fail closed on an existing audit constraint
- The host/backend boundary: hosts render and hand off; the Racket backend
  (`racket/autarx/backend.rkt`) decides. Crypto or policy sneaking into a
  native host is a bug.
- Local data handling: the workspace `.autarx/` directory (patch history,
  MCP audit log, vendor scratch), the crash-log directory
  `<TEMP>/autarx/crashes/`, and the Windows update throttle stamp
  `%LOCALAPPDATA%\autarx\last-update-check`

Out of scope: the behavior of the external vendor tools Autarx detects and
relays to (DaVinci Configurator, tresos Studio, ISOLAR) — their validation
verdicts belong to their vendors — as well as social engineering, physical
access attacks, and defects in GitHub Releases' own infrastructure.

## Design notes reviewers should know

- The backend owns no listening network port. Host ↔ backend RVT1 traffic
  runs over inherited file descriptors (`serve-fds`), and outbound network
  is limited to update checks and downloads against GitHub Releases
  (`racket/autarx/update.rkt`).
- **Crypto lives below the product.** The CLI channel verifies the signed
  manifest and the artifact's size and SHA-256 in the Racket backend
  (Ed25519 over the embedded runtime's FFI, SubjectPublicKeyInfo key form).
  The macOS workbench's checks run in rivet's `RivetUpdate` module — the
  Swift `UpdateService` contributes only the product facts (feed URL,
  embedded public key, key id `autarx-2026-10`, bundle name). The Windows
  and Linux hosts own UI and hand-off only; the backend verifies and
  downloads. Key rotation ships a build that trusts the next key before
  releases stop being signed with the old one.
- **The signed update feed does not imply a publisher-signed installer.**
  The DMG is ad-hoc signed (not notarized) and the MSI, deb, rpm and
  AppImage artifacts carry no publisher code signature. Releases do publish
  a checked `SHA256SUMS` covering every versioned artifact plus both signed
  manifests. Do not represent the feed signature as an independently
  trusted publisher identity.
- Local data is plain files and is not encrypted: the workspace `.autarx/`
  directory and the crash logs under `<TEMP>/autarx/crashes/`. Protection
  ultimately depends on OS user permissions and filesystem protection.
  Nothing here is telemetry: an OEM delivery never leaves the machine
  through Autarx.

## Supported versions

Security fixes land on `main` first and ship with the next tagged release.
During the 0.x preview there is no LTS branch.

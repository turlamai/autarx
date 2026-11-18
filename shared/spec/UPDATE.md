# Autarx Update Contract

> Online updates are the release vehicle: the user must be able to
> check, download, verify and install a new version without hunting for
> download pages. Autarx ships two deliverables with two update feeds,
> both Ed25519-signed wrappers in the family's `rivet/distribution`
> format: the **Windows workbench** updates in place through
> `update-app-manifest.json` (backend updater, `app-update.rkt`), and the
> **CLI** authenticates and applies `update-manifest.json` through
> `rivet/distribution` (`autarx update`). Autarx is a Windows-only
> product (issue #56): both feeds carry windows-x64 artifacts
> exclusively. This is the family contract — taskly's/brainfuel's
> `shared/spec/UPDATE.md` with the product substituted; the transport and
> install mechanism is native to each deliverable.

## Behavior contract (workbench, Windows x64)

- **Triggers**: one silent check shortly after launch (throttled: at
  most once per 4 hours, persisted as the `last-update-check` stamp
  under `%LOCALAPPDATA%\autarx` — a GUI-only concern, no
  backend round-trip), plus a manual `Check for Updates…` (Ctrl+U) menu
  entry that bypasses the throttle.
- **Silent mode**: network failure / rate limit → silently ignore
  (never nag). Manual mode reports every outcome.
- **Newer version found** (numeric per-segment compare, downgrades
  ignored) → panel with the new version: `Restart and Update` (download
  + install) or `Cancel`. Up-to-date → `Autarx is up to date`.
- **Download**: performed by the backend (`app-update.rkt` on rivet's
  managed updater) on a background thread — the wrapper signature, size
  and sha256 are enforced before anything is trusted; progress publishes
  through the `update_state` RPC (RVT1 events are thread-local, so the
  worker cannot emit them directly).
- **Install flavor follows the running copy**: an install under the
  Program Files tree takes the feed's signed `.msi` entry and the host
  hands off to a passive msiexec upgrade; a portable zip install swaps
  the install directory.
- **Install failure** → non-crashing error with the platform message;
  the running version keeps working.
- Strings are English-only, matching the workbench's single-language UI.

## Platform mechanisms

The release pipeline signs and uploads `update-app-manifest.json` (the
self-contained signed wrapper, below) for every release.

| Deliverable | Feed | Install | Integrity | Status |
|---|---|---|---|---|
| Workbench, MSI install (Windows x64) | `update-app-manifest.json` `windows`/`x64` msi entry | host hands off to a passive msiexec upgrade from the signed `.msi` | Ed25519 wrapper signature + artifact sha256 | live |
| Workbench, portable zip (Windows x64) | `update-app-manifest.json` `windows`/`x64` zip entry | host swaps the install directory from the verified payload | same | live |
| CLI (Windows x64) | `update-manifest.json` (signed wrapper, `rivet/distribution`) | download (size + sha256 enforced by `download-update`) → in-place file swap (`autarx.exe.autarx-update.old`) | Ed25519 wrapper signature (`key_id autarx-2026-10`) + artifact sha256 | live |

## Feed naming: `update-manifest.json` vs `update-app-manifest.json`

Two feeds, one format, one key. `update-manifest.json` (the family's
canonical name) is the CLI channel; `update-app-manifest.json` is the
workbench channel. They stay two files because the manifest schema
admits exactly one artifact per platform × architecture × installer,
and the workbench app payloads and the portable CLI zip are separate
update targets. Both are signed wrappers regenerated every release,
signed with the same `autarx-2026-10` key.

History: up to and including 0.2.0, `update-manifest.json` was the CLI's
plain `{version, assets}` checksum document and `latest.json` was a
byte-identical alias for pre-0.2.0 builds. The 0.4.1 release replaces
the checksum document with the signed wrapper and retires the alias —
the unauthenticated checksum feed was the supply-chain gap the family's
勿再手搓 direction closes. CLI builds up to and including 0.4.0 cannot
parse the signed wrapper and report a failed check; they need a one-off
manual install to cross over. (Those builds predate the Windows-only
reset; the version restart at 0.1.0 deleted the multi-platform releases
and tags.)

## Engine-side updater (CLI, `racket/autarx/update.rkt`)

`autarx update` requires `rivet/distribution` — `fetch-update-manifest`
(Ed25519 + key id, HTTPS-only, bounded bytes), `select-update` (channel,
version, minimum-version, rollout bucket, platform × architecture),
`download-update` (size + sha256 enforced against the signed manifest,
CDN redirections built in) and `updater-config`. Neither leg can hang:
the manifest fetch has a 60 s deadline and the download a 120 s stall /
30 min wall-clock watchdog (net/url ports have no read deadline). The
sticky rollout bucket (0–99, `crypto-random-bytes`) persists in
`updater-state.json` under `<temp>/autarx` — best-effort stickiness, the
release rollout is 100 today. The version is never embedded in the
updater module: it stays single-sourced in rivet.rktd /
rivet-app-info.rktd and is passed in by the CLI. The platform identity
is a constant pair (`windows`/`x64`) — shipped artifacts exist for
exactly that one pair, and the constant keeps `raco test racket/` green
on non-Windows dev machines.

## `update-app-manifest.json`

Generated by `scripts/make-update-manifest.sh` from the release
artifacts and uploaded as a single release asset. It is the family
signed-wrapper format (`rivet/distribution`): the inner manifest
travels base64-encoded inside a JSON envelope, so the Ed25519
signature covers the exact bytes every client verifies. The CLI
channel's `update-manifest.json` is generated the same way by
`scripts/make-update-feed.rkt` (CLI zip as the artifact; a missing
signing key fails the release — no key, no feed).

```json
{ "schema": 1,
  "payload": "<base64 of the inner manifest JSON bytes>",
  "signature": { "algorithm": "ed25519", "key_id": "autarx-2026-10",
                 "value": "<base64, 64 bytes>" } }
```

Inner manifest (snake_case): `schema, application_id
(site.jrtx.autarx.Autarx), version, build, channel (stable),
published_at (RFC 3339 UTC), minimum_version, previous_version,
rollback_allowed, rollout (0-100), artifacts[{platform, architecture,
url (HTTPS), sha256, size, installer, arguments}]`.

The publish job signs it with the `UPDATE_ED25519_PRIVATE_KEY_B64`
GitHub secret (OneAsymmetricKey DER, base64) and re-verifies the
signature before the release ships; a missing secret is a `::warning::`
and a release without the manifest — workbench builds then report
"release has no update manifest" instead of silently trusting an
unsigned feed.

## Key management

- Generate: `scripts/update-keys.sh` (OpenSSL 3; prints every derived
  form).
- GitHub secret: `UPDATE_ED25519_PRIVATE_KEY_B64`.
- Vault: `~/Sync/Keys` section `[autarx]` carries the DER forms and the
  public-key fingerprint (sha256(DER pub), first 16 hex).
- Embedded: the Racket updaters embed the same key in
  SubjectPublicKeyInfo form (`update-public-key-b64` in
  `racket/autarx/update.rkt` and `racket/autarx/app-update.rkt`) — one
  keypair, both channels; `scripts/check-update-signing-key.py` pins the
  agreement offline.
- Rotation ships a build that trusts the next key before releases stop
  being signed with the current one (`expectedKeyID` swap in the
  trusting release, then a signing-key flip in the pipeline).

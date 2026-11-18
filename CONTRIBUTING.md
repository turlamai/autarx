# Contributing to Autarx

Thank you for looking under the hood. Autarx is proprietary
(see [LICENSE](LICENSE)): by submitting a pull request you grant
TurLamAI the perpetual, irrevocable right to use, modify and distribute
your contribution as part of the Work under the same proprietary terms,
and you confirm you have the right to submit it. Contributions are not
licensed back to you under an open-source license; licensing for your own
use is a separate written agreement with the copyright holder.

## Ground rules

1. **The wire contract is host-wide.** `racket/autarx/backend.rkt`
   declares the typed RPC surface. Changing any of it requires
   regenerating the checked-in client with `raco rivet build`
   (`windows/GeneratedBackend.hpp`) in the same
   commit — it is a build input, never hand-edit it.
2. **The version has one source: `rivet.rktd`.** There is deliberately no
   version literal anywhere else — the CLI resolves it from the manifest
   and the host backend is regenerated from it by `raco rivet build`.
   `scripts/check-release-version.sh` enforces tag == `rivet.rktd` ==
   `GeneratedBackend.hpp` == CHANGELOG; do not reintroduce a second
   source (a stray package version literal drifted through four releases
   once).
3. **The acceptance contract is not negotiable.** `rivet-acceptance.rktd`
   pins the executable product requirements; `raco rivet acceptance
   --json` runs them. Never weaken a requirement to make a change green —
   change the requirement first, say why, and land spec and implementation
   in the same commit.
4. **Update trust is fail-closed.** Both release feeds are Ed25519-signed
   (contract: `shared/spec/UPDATE.md`, key id `autarx-2026-10`,
   keys: `scripts/update-keys.sh`). A failed verification aborts and the
   running version keeps working; there is no unsigned fallback path.
   `scripts/tests/test_release_signing.py` pins the offline trust-root
   contract.
5. **Privacy is a feature.** The signed update feed is the application's
   only network use. No telemetry, no accounts, OEM deliveries never
   leave the machine. New storage stays inside the workspace `.autarx/`
   directory (or `<TEMP>/autarx/crashes/` for crash logs).
6. **Fail honestly.** A malformed delivery exits with the finding on
   stderr; vendor relay reports the vendor tool's own verdict with the
   raw output preserved. No silent fallbacks.
7. **Tests pin contracts.** If you change behavior a test covers, change
   the test in the same commit and say why.

## Before you push

```bash
raco test racket/                                             # core contract tests
bash scripts/check-release-version.sh v0.1.0                  # tag must match rivet.rktd; pass the current version
python3 -m unittest discover -s scripts/tests -p 'test_release_signing.py'
python3 scripts/check_site_copy.py                            # site/content changes only
```

These mirror the CI `test`, `release-contract` and site-parity jobs. The
signing contract tests need OpenSSL 3 for Ed25519 — macOS's system
LibreSSL cannot generate the test keys, so put a real OpenSSL 3 first on
`PATH` (e.g. `/opt/homebrew/opt/openssl@3/bin`).
The Windows host compiles in its own CI job via `raco rivet build`; if
you touch `windows/`, say whether you were
able to build locally.

## Reporting issues

Include: OS + version, Autarx version (`autarx version`, or the About
dialog), installation shape (MSI / portable app zip / CLI zip),
the delivery fixture or minimal arxml that reproduces the problem, and
for CLI issues the exact argv plus the JSON error. For update failures,
include the error text from the update panel or the CLI output. Security
issues go through [SECURITY.md](SECURITY.md), not public issues.

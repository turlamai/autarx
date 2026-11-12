# Autarx user guide

**English** · [简体中文](USER-GUIDE.zh-CN.md)

Inspect, compare and trace AUTOSAR delivery data before making a reviewed change.

## Availability

Engineering preview; the complete official workbench is planned as a purchase. No paid checkout is open.

## Platforms and installation

Rivet desktop previews for macOS, Windows and Linux; CLI and MCP use the same Racket domain. Supported AUTOSAR scope is defined by the product contract, not every possible ARXML file.

Use [official Releases](https://github.com/turlamai/autarx/releases), select an explicitly listed OS/architecture asset, read its release notes and check supplied checksums. An absent asset/platform is not a delivery promise. Preview builds may lack publisher signing or notarization; do not disable system-wide security protections to install them.

## Your first successful session

1. Open the synthetic OemDelivery fixture before opening a confidential delivery.
2. Inspect unresolved references, compare two copies and review impact diagnostics. Treat unknown/ambiguous results as unresolved work.
3. For changes, generate a patch plan and semantic diff, inspect them, and only then apply to a disposable workspace copy.

## Data, backup and recovery

Keep an immutable original delivery. Back up the workspace, .autarx backups and audit/patch history together. A tool-generated diff is evidence for engineering review, not vendor validation or safety certification.

## Network, keys and privacy

Inspect/trace operations process local delivery files. Sharing diagnostics can disclose OEM/supplier names, paths and configuration. Review any external tool or agent integration before giving it workspace access.

## Known limits

Large-delivery performance budgets and full supported-scope qualification remain open (#22). Historical .NET releases are not the current Rivet implementation.

## Updates and removal

Back up data and read the destination release notes first. An in-app update check does not necessarily install an update for your channel; follow the manual for portable, installer and source paths. Never bypass a failed signature check or replace the program with an untrusted artifact. On failure, preserve data and the error, then recover with a trusted release. Removing the program does not necessarily erase its separate data directory; verify your backup before deleting personal data.

## Get help

Report problems in [GitHub Issues](https://github.com/turlamai/autarx/issues), in English or Chinese. Include the version, OS/architecture, installation channel, steps, expected result and actual result. Reproduce with synthetic input first; do not attach keys, credentials, databases, private source documents or complete logs. Public support has no guaranteed response time.

## Further reading

- [Workbench manual](../site/guide.html)
- [Supported product scope](../docs/PRODUCT.md)
- [Project overview and development](../README.md)
- [Current licence](../LICENSE)

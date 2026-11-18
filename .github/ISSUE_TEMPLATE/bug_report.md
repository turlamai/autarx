---
name: Bug report
about: Something in Autarx is broken or behaves differently from the docs
title: ''
labels: bug
assignees: ''
---

**Describe the bug**

A clear description of what happened and what you expected instead. If
this is a behavioral difference, name the reference (the archived v1.0.3
.NET implementation is the JSON/behaviour oracle).

**To reproduce**

Steps (or the exact CLI invocation / MCP tool call) that trigger the
behavior:

```
autarx inspect <delivery> --json
```

For GUI reports: the delivery's shape (OEM directory? single ARXML? which
vendor generator produced it — you can redact contents).

**Environment**

- Surface: GUI (Windows) / CLI / MCP server
- Autarx version: (Help ▸ About; the CLI prints `autarx <version>` in its
  banner)
- Install shape: msi / portable app zip / CLI zip
- Windows version

**Rule codes / JSON output**

If validation or a rule is involved, paste the ARX001–ARX006 / ARX-IMP-*
codes and the JSON payload (redact proprietary delivery data).

**Update context (if this happened during an update)**

- The exact error text — in the app you can select and copy the message
  in the update panel.

**Screenshots / logs**

If applicable, add screenshots, console output, or the
`.autarx/audit.jsonl` entry (redacted).

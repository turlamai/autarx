#!/usr/bin/env python3
"""Guard high-risk public claims against stale no-JS HTML fallbacks.

The website embeds its translated dictionaries in site/index.html. The HTML is
Chinese by default, and must state the same platform/maturity facts that JS
writes after load. This verifies copy equality only, never native readiness.
"""
from html import unescape
from pathlib import Path
import re
import sys

PAGE = Path(__file__).resolve().parents[1] / "site" / "index.html"
KEYS = (
    "pf.desktop-v",
    "pf.platforms-v",
    "pf.milestone-v",
    "pf.caption",
    "dl.lead",
    "status.lead",
)


def normalize(value):
    return re.sub(r"\s+", " ", unescape(value)).strip()


def main():
    source = PAGE.read_text(encoding="utf-8")
    failures = []
    for key in KEYS:
        html_re = rf'<(?:td|p)\b[^>]*data-i18n="{re.escape(key)}"[^>]*>(.*?)</(?:td|p)>'
        markup = re.search(html_re, source, re.DOTALL)
        dict_re = rf"'{re.escape(key)}'\s*:\s*'((?:\\.|[^'])*)'"
        translations = re.findall(dict_re, source)
        if markup is None or len(translations) != 2:
            failures.append(f"{key}: missing HTML fallback or expected 2 language entries")
            continue
        if normalize(markup.group(1)) != normalize(translations[0]):
            failures.append(f"{key}: no-JS Chinese HTML does not match Chinese dictionary")
    if failures:
        for error in failures:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print(f"OK: {len(KEYS)} critical no-JS HTML assertions match zh dictionary; EN keys present")
    print("NOTE: deployed content, real release assets and native behavior require separate validation")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/bin/sh
# Build the distributable autarx CLI: launcher + embedded Racket runtime
# tree + rivet-app-info.rktd, zipped for the update feed. The zip layout is
# exactly what `autarx update` swaps over an install directory (marker
# file: the `autarx.exe` launcher — the product ships Windows-only).
#
# Usage: scripts/build-cli.sh <output-dir>
# Produces <output-dir>/autarx/ (the distributable) and
#         <output-dir>/autarx-<version>-<os>-<arch>.zip
set -eu

OUT_DIR="${1:?usage: build-cli.sh <output-dir>}"
cd "$(dirname "$0")/.."
mkdir -p "$OUT_DIR"
# resolve to an absolute path: the zip step cds into the dist directory
OUT_DIR=$(cd "$OUT_DIR" && pwd)

VERSION=$(racket -e '(begin (require racket/file) (display (hash-ref (file->value "rivet.rktd") (quote version))))')
UNAME_S=$(uname -s)
if [ "$UNAME_S" = "Darwin" ]; then OS=macos; elif [ "$UNAME_S" = "Linux" ]; then OS=linux; else OS=windows; fi
UNAME_M=$(uname -m)
if [ "$UNAME_M" = "arm64" ] || [ "$UNAME_M" = "aarch64" ]; then ARCH=arm64; else ARCH=x64; fi

DIST="$OUT_DIR/autarx"
rm -rf "$DIST"
mkdir -p "$OUT_DIR"

echo "build-cli: launcher…"
# windows launchers carry a mandatory .exe suffix (raco exe appends it)
EXE=""
if [ "$OS" = "windows" ]; then EXE=".exe"; fi
LAUNCHER="$OUT_DIR/launcher-staging$EXE"
raco exe -o "$LAUNCHER" racket/autarx/cli.rkt

echo "build-cli: collect runtime (raco distribute)…"
# raco exe writes the launcher read-only; distribute patches it in place
chmod u+w "$LAUNCHER" 2>/dev/null || true
# distribute's rpath expects bin/ + lib/ siblings — keep that layout, the
# update payload swaps over the same shape
raco distribute "$OUT_DIR/collect" "$LAUNCHER"
rm -rf "$DIST"
mv "$OUT_DIR/collect" "$DIST"
# locate the distributed launcher wherever the platform put it (unix: bin/
# next to lib/; windows: flat next to the dlls) and rename it in place so
# relative library positions never change
DIST_LAUNCHER=$(find "$DIST" -name 'launcher-staging*' -print -quit)
test -n "$DIST_LAUNCHER" || { echo "build-cli: distribute produced no launcher" >&2; exit 1; }
mv "$DIST_LAUNCHER" "$(dirname "$DIST_LAUNCHER")/autarx$EXE"
APP_BIN="$(dirname "$DIST_LAUNCHER")/autarx$EXE"
chmod 555 "$APP_BIN" 2>/dev/null || true
rm -f "$OUT_DIR/launcher-staging$EXE"

echo "build-cli: write rivet-app-info.rktd…"
racket -e "(begin (require racket/file) (write-to-file (file->value \"rivet.rktd\") \"rivet-app-info.rktd\" #:exists 'truncate/replace))"
mv rivet-app-info.rktd "$DIST/rivet-app-info.rktd"

echo "build-cli: smoke (version must read from the metadata file)…"
"$APP_BIN" --help | head -1

ZIP="$OUT_DIR/autarx-$VERSION-$OS-$ARCH.zip"
if command -v zip >/dev/null 2>&1; then
  (cd "$DIST" && zip -qry "$ZIP" .)
else
  # windows runners ship PowerShell instead of zip
  powershell.exe -NoProfile -Command "Compress-Archive -Path '$(cygpath -w "$DIST")/*' -DestinationPath '$(cygpath -w "$ZIP")' -Force"
fi
echo "build-cli: $ZIP"

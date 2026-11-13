#!/usr/bin/env bash
# Build and sign the workbench update manifest
# (update-app-manifest.json — shared/spec/UPDATE.md).
#
#   scripts/make-update-manifest.sh <tag> <dist-dir> [key-path]
#
#   <tag>       release tag, e.g. v0.3.0 (must match rivet.rktd's version)
#   <dist-dir>  directory containing the release artifacts, i.e. the names
#               the release pipeline produces:
#                 autarx-<ver>-macos-arm64-app.zip    autarx-<ver>-macos-x64-app.zip
#                 autarx-<ver>-windows-x64-app.zip
#                 autarx-<ver>-linux-x64-app.tar.gz   autarx-<ver>-linux-arm64-app.tar.gz
#   <key-path>  Ed25519 private key: PEM (update-keys.sh output) or raw DER
#               (base64-decoded UPDATE_ED25519_PRIVATE_KEY_B64, the format
#               the release publish job consumes). Env fallbacks:
#               UPDATE_KEY_PATH, then the keys vault autarx section.
#
# Emits <dist-dir>/update-app-manifest.json — a single self-contained signed
# wrapper carrying the workbench update feed. The portable app zips (macOS,
# Windows) and the app tarballs (Linux) are the feed; the DMG/MSI/deb/rpm/
# AppImage are human installers, and the CLI keeps its own signed feed
# (update-manifest.json, a different file).
#
# The signing, artifact hashing, schema validation, and feed format live in
# `raco rivet sign-manifest`; this wrapper owns only Autarx's five artifacts,
# identity, and signing-key resolution.
set -euo pipefail

TAG="${1:?usage: make-update-manifest.sh <tag> <dist-dir> [key-path]}"
DIST="${2:?usage: make-update-manifest.sh <tag> <dist-dir> [key-path]}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$(cd "$DIST" && pwd)"
KEY="${3:-${UPDATE_KEY_PATH:-}}"

VERSION="${TAG#v}"
cd "$ROOT"
raco rivet check-release-version "$TAG"

# No explicit key and no env: pull the DER from the local keys vault
# (~/Sync/Keys autarx section, development signing only — CI passes the
# GitHub secret instead).
VAULT_TMP_KEY=""
if [[ -z "$KEY" ]]; then
  VAULT="$HOME/Sync/Keys/keys"
  [[ -x "$VAULT" ]] || { echo "error: no signing key (pass a key path, set UPDATE_KEY_PATH, or init the keys vault)" >&2; exit 1; }
  KEY="$(mktemp /tmp/autarx-key-XXXXXX)"
  VAULT_TMP_KEY=1
  "$VAULT" get autarx UPDATE_ED25519_PRIVATE_KEY_B64 | base64 -d > "$KEY"
fi

KEY_DER="$(mktemp /tmp/autarx-key-XXXXXX.der)"
trap 'rm -f "$KEY_DER"; [[ -n "$VAULT_TMP_KEY" ]] && rm -f "$KEY"' EXIT

# PEM input needs OpenSSL 3 (macOS ships LibreSSL, which cannot do Ed25519);
# DER input (the CI secret shape) needs nothing at all.
if head -c 30 "$KEY" | grep -q "BEGIN"; then
  OPENSSL_BIN="${OPENSSL_BIN:-}"
  if [[ -z "$OPENSSL_BIN" ]]; then
    for candidate in /opt/homebrew/opt/openssl@3/bin/openssl \
                     /usr/local/opt/openssl@3/bin/openssl openssl; do
      if command -v "$candidate" >/dev/null 2>&1 \
         && "$candidate" version 2>/dev/null | grep -q "OpenSSL 3"; then
        OPENSSL_BIN="$candidate"
        break
      fi
    done
  fi
  [[ -n "$OPENSSL_BIN" ]] || {
    echo "error: OpenSSL 3.x required for PEM keys (or pass DER base64-decoded)" >&2
    exit 1
  }
  "$OPENSSL_BIN" pkey -in "$KEY" -outform DER -out "$KEY_DER"
else
  cp "$KEY" "$KEY_DER"
fi

APP_ID="$(sed -nE 's/.*\(identifier \. "([^"]+)"\).*/\1/p' "$ROOT/rivet.rktd" | head -n1)"
BUILD="$(sed -nE 's/.*\(build \. ([0-9]+)\).*/\1/p' "$ROOT/rivet.rktd" | head -n1)"
[[ -n "$APP_ID" && -n "$BUILD" ]] || {
  echo "error: could not read application id/build from rivet.rktd" >&2
  exit 1
}
BASE_URL="${RELEASE_ASSET_BASE_URL:-https://github.com/turlamai/autarx/releases/download/$TAG}"

raco rivet sign-manifest \
  --application-id "$APP_ID" \
  --version "$VERSION" \
  --build "$BUILD" \
  --channel stable \
  --base-url "$BASE_URL" \
  --key-id autarx-2026-10 \
  --private-key "$KEY_DER" \
  --output "$DIST/update-app-manifest.json" \
  --artifact "macos:arm64:zip:$DIST/autarx-$VERSION-macos-arm64-app.zip" \
  --artifact "macos:x64:zip:$DIST/autarx-$VERSION-macos-x64-app.zip" \
  --artifact "windows:x64:zip:$DIST/autarx-$VERSION-windows-x64-app.zip" \
  --artifact "windows:x64:msi:$DIST/autarx-$VERSION-windows-x64.msi" \
  --artifact "linux:x64:targz:$DIST/autarx-$VERSION-linux-x64-app.tar.gz" \
  --artifact "linux:arm64:targz:$DIST/autarx-$VERSION-linux-arm64-app.tar.gz" \
  --artifact "linux:x64:appimage:$DIST/autarx-$VERSION-linux-x86_64.AppImage" \
  --artifact "linux:arm64:appimage:$DIST/autarx-$VERSION-linux-aarch64.AppImage" \
  --rollback-allowed

echo "manifest: $DIST/update-app-manifest.json (8 artifacts, application $APP_ID, key-id autarx-2026-10)"

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
# wrapper (schema + base64 payload + signature block): the family format
# every rivet/distribution client verifies. The portable app zips (macOS,
# Windows) and the app tarballs (Linux) are the workbench update feed; the
# DMG/MSI/deb/rpm/AppImage are human installers and stay out of it, and the
# CLI keeps its own signed feed (update-manifest.json, a different file).
# Requires racket with rivet linked (the release publish job installs the
# pinned checkout).
set -euo pipefail

TAG="${1:?usage: make-update-manifest.sh <tag> <dist-dir> [key-path]}"
DIST="${2:?usage: make-update-manifest.sh <tag> <dist-dir> [key-path]}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEY="${3:-${UPDATE_KEY_PATH:-}}"

VERSION="${TAG#v}"
RKTD_VERSION="$(sed -n 's/.*(version . "\([^"]*\)").*/\1/p' "$ROOT/rivet.rktd")"
[[ "$VERSION" == "$RKTD_VERSION" ]] || {
  echo "error: tag $TAG does not match rivet.rktd version '$RKTD_VERSION'" >&2; exit 1; }

for artifact in "$DIST/autarx-$VERSION-macos-arm64-app.zip" \
                "$DIST/autarx-$VERSION-macos-x64-app.zip" \
                "$DIST/autarx-$VERSION-windows-x64-app.zip" \
                "$DIST/autarx-$VERSION-linux-x64-app.tar.gz" \
                "$DIST/autarx-$VERSION-linux-arm64-app.tar.gz"; do
  [[ -f "$artifact" ]] || { echo "error: missing $artifact" >&2; exit 1; }
done

# No explicit key and no env: pull the DER from the local keys vault
# (~/Sync/Keys autarx section, development signing only — CI passes the
# GitHub secret instead).
if [[ -z "$KEY" ]]; then
  VAULT="$HOME/Sync/Keys/keys"
  [[ -x "$VAULT" ]] || { echo "error: no signing key (pass a key path, set UPDATE_KEY_PATH, or init the keys vault)" >&2; exit 1; }
  KEY="$(mktemp /tmp/autarx-key-XXXXXX)"
  VAULT_TMP_KEY=1
  "$VAULT" get autarx UPDATE_ED25519_PRIVATE_KEY_B64 | base64 -d > "$KEY"
fi
trap '[[ -n "${VAULT_TMP_KEY:-}" ]] && rm -f "$KEY"' EXIT

# PEM input needs OpenSSL 3 (macOS ships LibreSSL, which cannot do Ed25519);
# DER input (the CI secret shape) needs nothing at all.
KEY_DER="$(mktemp /tmp/autarx-key-XXXXXX)"
SCRIPT="$(mktemp /tmp/autarx-manifest-XXXXXX)"
trap 'rm -f "$SCRIPT" "$KEY_DER"; [[ -n "${VAULT_TMP_KEY:-}" ]] && rm -f "$KEY"' EXIT

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
  # rivet's signer reads DER (OneAsymmetricKey); convert the PEM once here.
  "$OPENSSL_BIN" pkey -in "$KEY" -outform DER -out "$KEY_DER"
else
  cp "$KEY" "$KEY_DER"
fi

cat > "$SCRIPT" <<RKT
#lang racket/base
(require rivet/distribution
         (only-in crypto pk-key->public-only-key)
         racket/date
         racket/file
         racket/format)
(define version "$VERSION")
(define base-url "${RELEASE_ASSET_BASE_URL:-https://github.com/turlamai/autarx/releases/download/$TAG}")
(define dist (path->complete-path "$DIST"))
(define key-path (path->complete-path "$KEY_DER"))
(define key-id "autarx-2026-10")
(define rktd (file->value (build-path (path->complete-path "$ROOT") "rivet.rktd")))
(define application-id (hash-ref rktd 'identifier))
(define build (hash-ref rktd 'build))

(define (artifact platform architecture file installer)
  (define path (build-path dist file))
  (unless (file-exists? path)
    (error 'make-update-manifest "missing installer: ~a" path))
  (update-artifact platform architecture
                   (string-append base-url "/" file)
                   (sha256-file/hex path)
                   (file-size path)
                   installer
                   '()))

(define manifest
  (update-manifest application-id
                   version
                   build
                   'stable
                   ;; published-at: RFC 3339, second precision, UTC
                   (let ([d (seconds->date (current-seconds) #f)])
                     (format "~a-~a-~aT~a:~a:~aZ"
                             (date-year d)
                             (~r (date-month d) #:min-width 2 #:pad-string "0")
                             (~r (date-day d) #:min-width 2 #:pad-string "0")
                             (~r (date-hour d) #:min-width 2 #:pad-string "0")
                             (~r (date-minute d) #:min-width 2 #:pad-string "0")
                             (~r (date-second d) #:min-width 2 #:pad-string "0")))
                   "0.0.0"
                   #f
                   #t
                   100
                   (list (artifact 'macos 'arm64
                                   (format "autarx-~a-macos-arm64-app.zip" version) 'zip)
                         (artifact 'macos 'x64
                                   (format "autarx-~a-macos-x64-app.zip" version) 'zip)
                         (artifact 'windows 'x64
                                   (format "autarx-~a-windows-x64-app.zip" version) 'zip)
                         (artifact 'linux 'x64
                                   (format "autarx-~a-linux-x64-app.tar.gz" version) 'targz)
                         (artifact 'linux 'arm64
                                   (format "autarx-~a-linux-arm64-app.tar.gz" version) 'targz))))

;; write-signed-manifest validates the struct against the manifest schema
;; before signing, so a malformed manifest fails the release instead of
;; shipping something every client would reject.
(call-with-output-file (build-path dist "update-app-manifest.json")
  #:exists 'truncate/replace
  (lambda (out)
    (write-signed-manifest manifest
                           (read-ed25519-private-key key-path)
                           key-id
                           out)
    (newline out)))

;; Sign → verify round trip: a private key whose public half differs from
;; the one embedded in the clients fails the release here, not in a
;; customer's update check.
(verify-signed-manifest
 (open-input-file (build-path dist "update-app-manifest.json"))
 (pk-key->public-only-key (read-ed25519-private-key key-path))
 #:key-id key-id)
(printf "manifest: ~a (5 artifacts, application ~a, key-id ~a)\\n"
        (build-path dist "update-app-manifest.json") application-id key-id)
RKT

# rivet must be installed for the signer; the release publish job links a
# checkout at the release pin.
racket "$SCRIPT"

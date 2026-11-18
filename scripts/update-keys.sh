#!/usr/bin/env bash
# Generate the Ed25519 keypair used to sign the update manifests
# (contract: shared/spec/UPDATE.md).
#
#   scripts/update-keys.sh [private-key-path]
#
# Default private key location: <repo>/.keys/update-signing-key.pem —
# gitignored, OUTSIDE the published tree. Back the PEM up somewhere safe
# (the keys vault ~/Sync/Keys autarx section carries the DER forms) and
# put the private DER (base64) into the GitHub secret
# UPDATE_ED25519_PRIVATE_KEY_B64 so release.yml can sign manifests.
# The script prints every derived form:
#   - public SPKI DER, base64     -> vault UPDATE_ED25519_PUBLIC_KEY_B64
#   - private OneAsymmetricKey DER, base64 -> GitHub secret + vault
# One-time: rotating requires a public-key rollout release (UPDATE.md).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEY_PATH="${1:-$ROOT/.keys/update-signing-key.pem}"

# Ed25519 needs OpenSSL 3+ (macOS ships LibreSSL, which cannot do it).
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
  echo "error: OpenSSL 3.x required for Ed25519 (brew install openssl@3," >&2
  echo "       or set OPENSSL_BIN=/path/to/openssl)" >&2
  exit 1
}

if [[ -f "$KEY_PATH" ]]; then
  echo "Private key already exists: $KEY_PATH" >&2
  echo "Delete it first if you really want to rotate (rotating requires a" >&2
  echo "public-key rollout release — see shared/spec/UPDATE.md)." >&2
  exit 1
fi

mkdir -p "$(dirname "$KEY_PATH")"
chmod 700 "$(dirname "$KEY_PATH")"
umask 077
"$OPENSSL_BIN" genpkey -algorithm ed25519 -out "$KEY_PATH"

PUB_SPKI_B64="$("$OPENSSL_BIN" pkey -in "$KEY_PATH" -pubout -outform DER 2>/dev/null | base64)"
PRIV_DER_B64="$("$OPENSSL_BIN" pkey -in "$KEY_PATH" -outform DER 2>/dev/null | base64 | tr -d '\n')"

echo "Private key (PEM): $KEY_PATH"
echo "  Back this up; never commit it."
echo
echo "Public key, SPKI DER base64 — vault UPDATE_ED25519_PUBLIC_KEY_B64:"
echo "  $PUB_SPKI_B64"
echo
echo "Private key, OneAsymmetricKey DER base64 — GitHub secret"
echo "UPDATE_ED25519_PRIVATE_KEY_B64 (release.yml signing):"
echo "  $PRIV_DER_B64"

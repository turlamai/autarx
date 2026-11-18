#!/usr/bin/env python3
"""Fail closed unless the release Ed25519 key matches all Autarx update clients."""
import base64
import binascii
import hmac
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
SPKI_PREFIX = bytes.fromhex("302a300506032b6570032100")
RACKET_CLIENTS = ("racket/autarx/update.rkt", "racket/autarx/app-update.rkt")


def decode_key(value, label):
    try:
        return base64.b64decode(value, validate=True)
    except (ValueError, binascii.Error) as exc:
        raise ValueError(f"invalid {label} base64") from exc


def trusted_public_key(root=ROOT):
    """Verify both embedded Racket SPKI keys agree."""
    keys = []
    for relative in RACKET_CLIENTS:
        source = (Path(root) / relative).read_text(encoding="utf-8")
        match = re.search(
            r'\(define\s+update-public-key-b64\s+"([A-Za-z0-9+/=]+)"\s*\)', source
        )
        if not match:
            raise ValueError(f"missing embedded public key: {relative}")
        der = decode_key(match.group(1), relative)
        if len(der) != 44 or not der.startswith(SPKI_PREFIX):
            raise ValueError(f"invalid Ed25519 SPKI key: {relative}")
        keys.append(der)
    if not hmac.compare_digest(keys[0], keys[1]):
        raise ValueError("CLI and workbench Racket public keys differ")
    return keys[0]


def verify(private_der, expected_spki):
    if not private_der:
        raise ValueError("missing release Ed25519 private key")
    try:
        result = subprocess.run(
            ["openssl", "pkey", "-inform", "DER", "-pubout", "-outform", "DER"],
            input=private_der, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            check=False,
        )
    except OSError as exc:
        raise ValueError("OpenSSL pkey unavailable") from exc
    if result.returncode != 0 or not result.stdout:
        raise ValueError("invalid release Ed25519 private key")
    if not hmac.compare_digest(result.stdout, expected_spki):
        raise ValueError("release Ed25519 key does not match embedded updater keys")


def verify_secret(encoded, root=ROOT):
    if not encoded:
        raise ValueError("missing UPDATE_ED25519_PRIVATE_KEY_B64")
    private_der = decode_key(encoded, "release private key")
    verify(private_der, trusted_public_key(root))


def main():
    try:
        verify_secret(os.environ.get("UPDATE_ED25519_PRIVATE_KEY_B64", ""))
    except (ValueError, OSError) as exc:
        print(f"::error::{exc}", file=sys.stderr)
        return 1
    print("Ed25519 release key matches the Racket CLI and workbench trust roots")
    return 0


if __name__ == "__main__":
    sys.exit(main())

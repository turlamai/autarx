#!/usr/bin/env bash
# Release version preflight: the tag, the version single source and the
# CHANGELOG must agree before a release goes out.
#
# autarx's version single source is rivet.rktd (the Rivet app manifest that
# feeds both the Windows package and the CLI's rivet-app-info.rktd). There
# is deliberately no version literal anywhere else — cli.rkt resolves it
# from the manifest and GeneratedBackend.hpp is regenerated from it by
# `raco rivet build`; the checks below enforce exactly that.
#
# Usage: scripts/check-release-version.sh [tag]
#        (tag like v0.1.0; falls back to GITHUB_REF_NAME in CI)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="${1:-${GITHUB_REF_NAME:-}}"

fail() {
  echo "release preflight: $*" >&2
  exit 1
}

VERSION="$(racket -e '(begin (require racket/file) (display (hash-ref (file->value "rivet.rktd") (quote version))))')"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]] || \
  fail "rivet.rktd version '$VERSION' is not a supported semantic version"

[[ -n "$TAG" ]] || fail "no tag given (argument or GITHUB_REF_NAME)"
TAG_VERSION="${TAG#v}"
[[ "$TAG_VERSION" == "$VERSION" ]] || \
  fail "tag '$TAG' does not match rivet.rktd version '$VERSION'"

# The release must be announced in the CHANGELOG (`## [x.y.z]` or `## x.y.z`).
grep -Eq "^## \[?$TAG_VERSION\]" "$ROOT/CHANGELOG.md" || \
  fail "CHANGELOG.md has no '## $TAG_VERSION' section"

# No version literal may creep back into the CLI — the manifest is the only
# source (this shipped a stale 1.0.0 launcher once).
if grep -Eq '\(version-from-app-info\) *"' "$ROOT/racket/autarx/cli.rkt"; then
  fail "racket/autarx/cli.rkt carries a hardcoded version fallback literal"
fi

# The raco package must not grow its own version literal either — rivet
# packaging reads the product version only from rivet.rktd, so a package
# version here is a second source that floats free of every release
# ("2.0.0-alpha.1" drifted against the product through four releases).
if grep -Eq '^\(define version ' "$ROOT/racket/info.rkt"; then
  fail "racket/info.rkt carries a package version literal (the product version is single-sourced in rivet.rktd)"
fi

# The checked-in generated Windows backend must match the manifest.
HOST_VERSION="$(sed -nE 's/.*kVersion\[\] = "([^"]+)".*/\1/p' \
  "$ROOT/windows/GeneratedBackend.hpp" | head -n1)"
[[ -n "$HOST_VERSION" ]] || \
  fail "cannot read version from windows/GeneratedBackend.hpp"
[[ "$HOST_VERSION" == "$VERSION" ]] || \
  fail "GeneratedBackend.hpp version '$HOST_VERSION' does not match rivet.rktd '$VERSION' (run: raco rivet build)"

echo "release preflight: version $VERSION is aligned (tag $TAG == rivet.rktd == GeneratedBackend.hpp, CHANGELOG ok)"

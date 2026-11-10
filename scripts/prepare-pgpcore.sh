#!/usr/bin/env bash
# Apply the compatibility patch only to the exact public dependency revision.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
core="${PASSPONY_PGPCORE:-$root/../NorseHorsePGPCore}"
patch="$root/patches/norsehorse-pgpcore-891670c.patch"
expected=891670cd4806fdf26927c37f73fb1447b0d16887
actual="$(git -C "$core" rev-parse HEAD)"
if [[ "$actual" != "$expected" ]]; then
  echo "NorseHorsePGPCore must be checked out at $expected (found $actual)." >&2
  exit 1
fi
if git -C "$core" apply --reverse --check "$patch" 2>/dev/null; then
  echo "OpenPGP compatibility patch is already applied."
  exit 0
fi
if ! git -C "$core" diff --quiet || ! git -C "$core" diff --cached --quiet; then
  echo "NorseHorsePGPCore has local changes; refusing to modify it." >&2
  exit 1
fi
git -C "$core" apply --check "$patch"
git -C "$core" apply "$patch"
echo "Applied the OpenPGP compatibility patch to $expected."

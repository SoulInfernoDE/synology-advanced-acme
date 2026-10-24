#!/bin/bash
# Replace vendor/acme.sh with an official acme.sh release.
#
#   tools/update-vendor.sh 3.1.6
#
# Only the runtime parts are kept: acme.sh, dnsapi/, deploy/, notify/, LICENSE.md.
set -euo pipefail
cd "$(dirname "$0")/.."
TAG="${1:?usage: tools/update-vendor.sh <acme.sh release tag>}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

curl -fsSL "https://github.com/acmesh-official/acme.sh/archive/refs/tags/${TAG}.tar.gz" -o "$TMP/acme.tar.gz"
tar -xzf "$TMP/acme.tar.gz" -C "$TMP"
SRC="$(dirname "$(find "$TMP" -mindepth 2 -maxdepth 2 -name acme.sh -type f | head -n1)")"
VER="$(sed -n 's/^VER=//p' "$SRC/acme.sh" | head -n1)"
[ "$VER" = "${TAG#v}" ] || { echo "version mismatch: tag $TAG, acme.sh says $VER" >&2; exit 1; }

rm -rf vendor/acme.sh
mkdir -p vendor/acme.sh
cp -a "$SRC/acme.sh" "$SRC/dnsapi" "$SRC/deploy" "$SRC/notify" "$SRC/LICENSE.md" vendor/acme.sh/
printf '%s\n' "$VER" >vendor/acme.sh/VERSION.txt
echo "vendor/acme.sh is now acme.sh $VER"

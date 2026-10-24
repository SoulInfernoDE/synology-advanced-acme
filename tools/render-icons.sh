#!/bin/bash
# Render the PNG icons DSM needs from assets/icon.svg (requires Inkscape).
set -euo pipefail
cd "$(dirname "$0")/.."
out=src/ui/images
mkdir -p "$out" package
for s in 16 24 32 48 64 72 90 120 128 256; do
  inkscape assets/icon.svg --export-type=png --export-filename="$out/icon_$s.png" -w "$s" -h "$s" >/dev/null 2>&1
done
cp "$out/icon_64.png" package/PACKAGE_ICON.PNG
cp "$out/icon_256.png" package/PACKAGE_ICON_256.PNG
echo "icons written to $out"

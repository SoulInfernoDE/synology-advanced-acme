#!/bin/bash
# Build the Advanced ACME DSM package (noarch SPK for DSM 7.0+).
#
#   ./build.sh            -> dist/AdvancedACME-<version>-noarch.spk
#
# Requirements: bash, tar, gzip, python3 (build time only).
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$PWD"
PKG="AdvancedACME"
VERSION="$(tr -d '[:space:]' < VERSION)"
MAINTAINER="${MAINTAINER:-Advanced ACME Project}"
BUILD="$ROOT/build"
STAGE="$BUILD/stage"
OUT="$ROOT/dist"

rm -rf "$BUILD"
mkdir -p "$STAGE/target" "$STAGE/spk" "$OUT"
T="$STAGE/target"

# --- package.tgz contents (installed to /var/packages/AdvancedACME/target) ---
cp -a src/bin src/lib src/ui "$T/"
mkdir -p "$T/acme.sh" "$T/share"
cp -a src/share/. "$T/share/"
cp -a vendor/acme.sh/acme.sh vendor/acme.sh/dnsapi vendor/acme.sh/deploy vendor/acme.sh/notify "$T/acme.sh/"
cp vendor/acme.sh/LICENSE.md "$T/acme.sh/LICENSE.md"
cp src/acme-hooks/deploy/*.sh "$T/acme.sh/deploy/"
python3 -I tools/gen-dnsapi.py vendor/acme.sh/dnsapi "$T/ui/dnsapi.json" "$T/share/dnsapi.keys"
echo "$VERSION" > "$T/VERSION"
# DSM serves the UI without cache headers: version the asset URLs so browsers
# load the new files after a package update.
sed -i "s/\"app\.\(js\|css\)\"/\"app.\1?v=${VERSION}\"/" "$T/ui/index.html"
cp LICENSE "$T/LICENSE"

find "$T" -type d -exec chmod 755 {} +
find "$T" -type f -exec chmod 644 {} +
chmod 755 "$T/bin/advanced-acme" "$T/ui/api.cgi" "$T/acme.sh/acme.sh"
chmod 755 "$T"/acme.sh/dnsapi/*.sh "$T"/acme.sh/deploy/*.sh "$T"/acme.sh/notify/*.sh

tar --owner=0 --group=0 --numeric-owner --sort=name -C "$T" -czf "$STAGE/spk/package.tgz" .

# --- SPK control files ---
cp -a package/conf package/scripts package/WIZARD_UIFILES "$STAGE/spk/"
chmod 755 "$STAGE"/spk/scripts/*
cp package/PACKAGE_ICON.PNG package/PACKAGE_ICON_256.PNG "$STAGE/spk/"
cp LICENSE "$STAGE/spk/LICENSE"

CHECKSUM="$(md5sum "$STAGE/spk/package.tgz" | cut -d' ' -f1)"

# Package Center descriptions: package/descriptions/<DSM language code>.txt
DESCRIPTIONS="description=\"$(tr -d '\n"' < package/descriptions/enu.txt)\""
for f in package/descriptions/*.txt; do
  code="$(basename "$f" .txt)"
  DESCRIPTIONS+=$'\n'"description_${code}=\"$(tr -d '\n"' < "$f")\""
done
cat > "$STAGE/spk/INFO" <<INFO
package="$PKG"
version="$VERSION"
os_min_ver="7.0-40000"
displayname="Advanced ACME"
$DESCRIPTIONS
maintainer="$MAINTAINER"
arch="noarch"
thirdparty="yes"
beta="yes"
dsmuidir="ui"
dsmappname="SYNO.SDS.$PKG.Application"
startable="yes"
ctl_stop="yes"
silent_upgrade="yes"
support_center="no"
checksum="$CHECKSUM"
INFO

SPK="$OUT/${PKG}-${VERSION}-noarch.spk"
rm -f "$SPK"
tar --owner=0 --group=0 --numeric-owner -C "$STAGE/spk" -cf "$SPK" \
  INFO package.tgz scripts conf WIZARD_UIFILES PACKAGE_ICON.PNG PACKAGE_ICON_256.PNG LICENSE
echo "built $SPK ($(du -h "$SPK" | cut -f1))"

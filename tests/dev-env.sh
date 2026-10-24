#!/bin/bash
# Local development environment for the web UI:
#   Pebble (ACME test CA with EAB, 180-day certificates), pebble-challtestsrv,
#   the DSM/IONOS mock and the UI dev server on http://127.0.0.1:${PORT:-8099}
#
# In the UI use provider "Other ACME server" with https://localhost:14000/dir,
# EAB Key ID kid-1 and HMAC key from Pebble's test config, DNS provider
# "Pebble challenge test server", DSM account certbot / "s3cret pass&=",
# IONOS key prefix pfx123 / secret secret456.
set -u
cd "$(dirname "$0")/.."
ROOT="$PWD"
PORT="${PORT:-8099}"
MOCK_PORT=15510
PEBBLE_BIN_DIR="${PEBBLE_BIN_DIR:-$(dirname "$(command -v pebble 2>/dev/null || echo /nonexistent/pebble)")}"
PEBBLE_SRC="$(ls -d "$(go env GOMODCACHE)"/github.com/letsencrypt/pebble/v2@*/ | tail -n1)"
W="$ROOT/.dev"
PIDS=()
trap 'for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done' EXIT

./build.sh >/dev/null || exit 1
rm -rf "$W/target"
mkdir -p "$W/var"
cp -a build/stage/target "$W/target"
T="$W/target"
cp tests/dns_pebble.sh "$T/acme.sh/dnsapi/"
echo "dns_pebble PEBBLE_CHALL_URL" >>"$T/share/dnsapi.keys"
python3 -I tools/gen-dnsapi.py "$T/acme.sh/dnsapi" "$T/ui/dnsapi.json" /dev/null >/dev/null
printf 'administrators:x:101:admin\n' >"$W/group"
printf 'admin_port="%s"\n' "$MOCK_PORT" >"$W/synoinfo.conf"
jq '.pebble.profiles = {"default": {"description": "180 days", "validityPeriod": 15552000}} | .pebble.listenAddress = "127.0.0.1:14000" | .pebble.managementListenAddress = "127.0.0.1:15000"' \
  "$PEBBLE_SRC/test/config/pebble-config-external-account-bindings.json" >"$W/pebble.json"

(cd "$PEBBLE_SRC" && exec "$PEBBLE_BIN_DIR/pebble-challtestsrv" -dnsserver 127.0.0.1:8053 -http01 "" -https01 "" \
  -tlsalpn01 "" -doh "" -management 127.0.0.1:8055 >"$W/challtestsrv.log" 2>&1) &
PIDS+=($!)
(cd "$PEBBLE_SRC" && PEBBLE_VA_NOSLEEP=1 PEBBLE_WFE_NONCEREJECT=0 exec "$PEBBLE_BIN_DIR/pebble" \
  -config "$W/pebble.json" -dnsserver 127.0.0.1:8053 >"$W/pebble.log" 2>&1) &
PIDS+=($!)
python3 -I tests/mock_server.py "$MOCK_PORT" >"$W/mock.log" 2>&1 &
PIDS+=($!)

export AACME_TARGET="$T" AACME_VAR="$W/var"
export AACME_AUTH_CGI="$ROOT/tests/fake_authenticate.cgi" AACME_LOGIN_CGI=/bin/true
export AACME_GROUP_FILE="$W/group" AACME_SYNOINFO="$W/synoinfo.conf"
export AACME_IONOS_API="http://127.0.0.1:${MOCK_PORT}/dns"
export AACME_DSM_LAN_HOST=127.0.0.2
export CA_BUNDLE="$PEBBLE_SRC/test/certs/pebble.minica.pem" Le_DNSSleep=1
export AACME_TASK_RUN="$W/run" AACME_SYNOWEBAPI="$ROOT/tests/fake_synowebapi.py" AACME_TASK_PKGDIR="$T"
# The DSM mock starts the DSM task's script in the background when Advanced
# ACME sets it up, like DSM; stop it together with the environment.
trap 'for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; pkill -f "Q='"'"'$W/var/dsm-task'"'"'" 2>/dev/null' EXIT
echo "UI: http://127.0.0.1:${PORT}/index.html"
python3 -I tests/devserver.py "$PORT"

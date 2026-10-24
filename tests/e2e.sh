#!/bin/bash
# End-to-end test of the backend through the CGI API.
#
# Uses Pebble (ACME test CA with External Account Binding and 180-day
# certificates, like IONOS), pebble-challtestsrv for DNS-01, and a mock of the
# DSM Web API and the IONOS DNS API.
#
# Requirements: pebble and pebble-challtestsrv in PATH or PEBBLE_BIN_DIR,
#               Go module cache with pebble's test certificates, python3, jq, curl.
set -u
cd "$(dirname "$0")/.."
ROOT="$PWD"
W="$ROOT/build/e2e"
PEBBLE_BIN_DIR="${PEBBLE_BIN_DIR:-$(dirname "$(command -v pebble 2>/dev/null || echo /nonexistent/pebble)")}"
PEBBLE_SRC="$(ls -d "$(go env GOMODCACHE)"/github.com/letsencrypt/pebble/v2@*/ | tail -n1)"
MOCK_PORT=15500
PASS=0
FAIL=0
PIDS=()

cleanup() {
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
  SYNOPKG_PKGDEST="$T" SYNOPKG_PKGVAR="$V" "$ROOT/package/scripts/start-stop-status" stop >/dev/null 2>&1
  # DSM task scripts the mock started in the background
  pkill -f "Q='$V/dsm-task'" 2>/dev/null
}
trap cleanup EXIT

ok() { PASS=$((PASS + 1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/       /' | tail -n 40; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

# --- Setup ---------------------------------------------------------------------
./build.sh >/dev/null || { echo "build failed"; exit 1; }
rm -rf "$W"
mkdir -p "$W"
T="$W/target"
V="$W/var"
cp -a build/stage/target "$T"
cp tests/dns_pebble.sh "$T/acme.sh/dnsapi/"
echo "dns_pebble PEBBLE_CHALL_URL" >>"$T/share/dnsapi.keys"
mkdir -p "$V" "$W/pkgdir"
printf 'administrators:x:101:admin,root\nusers:x:100:bob\n' >"$W/group"
printf 'admin_port="%s"\nsecure_admin_port="15501"\n' "$MOCK_PORT" >"$W/synoinfo.conf"

jq '.pebble.profiles = {"default": {"description": "180 days like IONOS", "validityPeriod": 15552000}} | .pebble.listenAddress = "127.0.0.1:14000" | .pebble.managementListenAddress = "127.0.0.1:15000"' \
  "$PEBBLE_SRC/test/config/pebble-config-external-account-bindings.json" >"$W/pebble.json"
(cd "$PEBBLE_SRC" && exec "$PEBBLE_BIN_DIR/pebble-challtestsrv" -dnsserver 127.0.0.1:8053 -http01 "" -https01 "" -tlsalpn01 "" -doh "" \
  -management 127.0.0.1:8055 -defaultIPv4 127.0.0.1 >"$W/challtestsrv.log" 2>&1) &
PIDS+=($!)
(cd "$PEBBLE_SRC" && PEBBLE_VA_NOSLEEP=1 PEBBLE_WFE_NONCEREJECT=0 PEBBLE_AUTHZREUSE=0 exec \
  "$PEBBLE_BIN_DIR/pebble" -config "$W/pebble.json" -dnsserver 127.0.0.1:8053 >"$W/pebble.log" 2>&1) &
PIDS+=($!)
python3 -I tests/mock_server.py "$MOCK_PORT" >"$W/mock.log" 2>&1 &
PIDS+=($!)
for _ in $(seq 1 50); do
  curl -sk https://localhost:14000/dir >/dev/null 2>&1 && curl -s "http://127.0.0.1:${MOCK_PORT}/_state" >/dev/null 2>&1 && break
  sleep 0.2
done

export AACME_TARGET="$T" AACME_VAR="$V"
export AACME_AUTH_CGI="$ROOT/tests/fake_authenticate.cgi" AACME_LOGIN_CGI=/bin/true
export AACME_GROUP_FILE="$W/group" AACME_SYNOINFO="$W/synoinfo.conf"
export AACME_IONOS_API="http://127.0.0.1:${MOCK_PORT}/dns"
export AACME_DSM_LAN_HOST=127.0.0.2
# DSM task: results in a test folder, synowebapi and the package folder
# replaced for the test.
export AACME_TASK_RUN="$W/run" AACME_SYNOWEBAPI="$ROOT/tests/fake_synowebapi.py" AACME_TASK_PKGDIR="$W/pkgdir"
export AACME_TASK_WAIT=30 AACME_TASK_INTERVAL=1 AACME_TASK_GRACE=3
export CA_BUNDLE="$PEBBLE_SRC/test/certs/pebble.minica.pem"
# Pebble's DNS is private: skip acme.sh's public DNS propagation check.
export Le_DNSSleep=1

# Fake acme.sh releases for the update tests: 3.1.99 is valid, 3.1.98 is a
# broken archive whose acme.sh reports a different version, 3.1.97 lacks the
# DNS plugin used by the test certificates.
for v in 3.1.99 3.1.98 3.1.97; do
  mkdir -p "$W/rel/acme.sh-$v"
  cp -a vendor/acme.sh/. "$W/rel/acme.sh-$v/"
  [ "$v" = 3.1.97 ] || cp tests/dns_pebble.sh "$W/rel/acme.sh-$v/dnsapi/"
  sed -i "s/^VER=.*/VER=$([ "$v" = 3.1.98 ] && echo 3.1.96 || echo "$v")/" "$W/rel/acme.sh-$v/acme.sh"
  tar -czf "$W/acme-$v.tar.gz" -C "$W/rel" "acme.sh-$v"
done
printf '{"tag_name": "3.1.99"}' >"$W/latest.json"
export AACME_ACME_RELEASES_API="file://$W/latest.json" AACME_ACME_TARBALL_URL="file://$W/acme-{tag}.tar.gz"
PEBBLE_DIR="https://localhost:14000/dir"

# cgi KEY=VALUE...: POST to api.cgi, print the JSON body.
cgi() {
  local body="" kv k v
  for kv in "$@"; do
    k="${kv%%=*}"
    v="${kv#*=}"
    body+="${body:+&}$(jq -rn --arg s "$k" '$s|@uri')=$(jq -rn --arg s "$v" '$s|@uri')"
  done
  printf '%s' "$body" | REQUEST_METHOD=POST HTTP_X_AACME="${XAACME-1}" CONTENT_LENGTH="$(printf '%s' "$body" | wc -c)" \
    "$T/ui/api.cgi" | tr -d '\r' | sed '1,/^$/d'
}

# wait_job JOBID: wait until done, print final status JSON.
wait_job() {
  local r
  for _ in $(seq 1 300); do
    r="$(cgi action=job id="$1")"
    [ "$(jq -r .state <<<"$r")" = "done" ] && { printf '%s' "$r"; return; }
    sleep 1
  done
  printf '%s' "$r"
}

mock_state() { curl -s "http://127.0.0.1:${MOCK_PORT}/_state"; }

echo "== Bundled acme.sh"
check "bundled acme.sh waits longer for certificates still being issued" '[ "$(grep -c "_sleep \"\$(_retry_backoff_sec \"\$(_math \"\$_link_cert_retry\" + 1)\")\"" "$T/acme.sh/acme.sh")" = 2 ] && grep -q "_MAX_CERT_RETRY=\"\${MAX_CERT_RETRY_TIMES:-30}\"" "$T/acme.sh/acme.sh"'

echo "== API security"
r="$(XAACME="" cgi action=status)"
check "request without X-AACME header is refused" '[ "$(jq -r .error <<<"$r")" = csrf ]' "$r"
r="$(FAKE_DSM_USER=bob cgi action=status)"
check "non-admin user is refused" '[ "$(jq -r .error <<<"$r")" = not_admin ]' "$r"
r="$(FAKE_DSM_USER="" cgi action=status)"
check "anonymous request is refused" '[ "$(jq -r .error <<<"$r")" = not_logged_in ]' "$r"

echo "== Status and settings"
r="$(cgi action=status)"
BUNDLED_VER="$(cat vendor/acme.sh/VERSION.txt)"
check "status ok, acme.sh version reported" '[ "$(jq -r .acme_version <<<"$r")" = "$BUNDLED_VER" ] && [ "$(jq -r .acme.updated <<<"$r")" = false ] && [ "$(jq -r .dsm.configured <<<"$r")" = false ]' "$r"
r="$(cgi action=settings_set key=renew_before_days value=999)"
check "invalid setting rejected" '[ "$(jq -r .error <<<"$r")" = invalid_setting ]' "$r"
r="$(cgi action=settings_set key=evil value=1)"
check "unknown setting rejected" '[ "$(jq -r .error <<<"$r")" = invalid_setting ]' "$r"
r="$(cgi action=settings_set key=renew_before_days value=45)"
check "valid setting stored" '[ "$(jq -r .ok <<<"$r")" = true ] && [ "$(jq -r .settings.renew_before_days <<<"$(cgi action=status)")" = 45 ]' "$r"
cgi action=settings_set key=renew_before_days value=30 >/dev/null

echo "== IONOS DNS key check"
r="$(cgi action=ionos_zones prefix=pfx123 secret=wrong)"
check "wrong IONOS key rejected and not stored" '[ "$(jq -r .error <<<"$r")" = ionos_key_rejected ] && ! grep -q "^SAVED_IONOS" "$V/acme/account.conf" 2>/dev/null' "$r"
r="$(cgi action=ionos_zones prefix=pfx123 secret=secret456)"
check "IONOS zones listed" '[ "$(jq -c .zones <<<"$r")" = "[\"example.test\",\"other.test\"]" ]' "$r"
r="$(cgi action=dns_saved keys=IONOS_PREFIX,IONOS_SECRET)"
check "working IONOS key stored for renewals (acme.sh format)" '[ "$(jq -r ".saved.IONOS_PREFIX and .saved.IONOS_SECRET" <<<"$r")" = true ] && grep -qx "SAVED_IONOS_SECRET=.secret456." "$V/acme/account.conf"' "$r"
r="$(cgi action=ionos_zones)"
check "stored IONOS key is used without entering it again" '[ "$(jq -r .saved <<<"$r")" = true ] && [ "$(jq -r ".zones | length" <<<"$r")" = 2 ]' "$r"

echo "== DSM account"
r="$(cgi action=dsm_check user=certbot pass=wrong)"
check "wrong DSM password -> dsm_auth_400" '[ "$(jq -r .error <<<"$r")" = dsm_auth_400 ]' "$r"
r="$(cgi action=dsm_check user=viewer pass=pw)"
check "non-admin DSM account -> dsm_list_105" '[ "$(jq -r .error <<<"$r")" = dsm_list_105 ]' "$r"
r="$(cgi action=dsm_check user=otpuser pass=pw)"
check "2FA account without code -> dsm_auth_403" '[ "$(jq -r .error <<<"$r")" = dsm_auth_403 ]' "$r"
r="$(cgi action=dsm_check user=otpuser pass=pw otp=000000)"
check "2FA account with wrong code -> dsm_auth_404" '[ "$(jq -r .error <<<"$r")" = dsm_auth_404 ]' "$r"
r="$(cgi action=dsm_check user=otpuser pass=pw otp=123456)"
check "2FA account with code -> ok, device token stored" '[ "$(jq -r .ok <<<"$r")" = true ] && grep -q "^device_id=dev-1$" "$V/secrets/dsm.conf"' "$r"
r="$(cgi action=dsm_check)"
check "stored 2FA account signs in with device token" '[ "$(jq -r .ok <<<"$r")" = true ] && [ "$(mock_state | jq -r ".logins[-1].device_id")" = dev-1 ]' "$r"
check "DSM certificate list returned" '[ "$(jq -r ".dsm.data.certificates[0].id" <<<"$r")" = def01 ]' "$r"
check "secrets file is private (600)" '[ "$(stat -c %a "$V/secrets/dsm.conf")" = 600 ]'
r="$(cgi action=dsm_check "user=certbot" "pass=s3cret pass&=")"
check "password with special characters works, device token reset" '[ "$(jq -r .ok <<<"$r")" = true ] && ! grep -q "^device_id=" "$V/secrets/dsm.conf"' "$r"
check "detected DSM connection from synoinfo.conf" '[ "$(jq -r .scheme <<<"$r"):$(jq -r .port <<<"$r")" = "http:$MOCK_PORT" ]' "$r"

echo "== DSM service account created by the wizard"
r="$(cgi action=dsm_create_service user=viewer pass=pw)"
check "non-admin cannot create the service account -> dsm_list_105" '[ "$(jq -r .error <<<"$r")" = dsm_list_105 ] && [ "$(mock_state | jq -r ".users[\"advanced-acme\"]")" = null ]' "$r"
curl -s "http://127.0.0.1:${MOCK_PORT}/_set?adduser=advanced-acme&desc=someone" >/dev/null
r="$(cgi action=dsm_create_service "user=certbot" "pass=s3cret pass&=")"
check "foreign user with the same name is not taken over" '[ "$(jq -r .error <<<"$r")" = dsm_svc_exists ] && [ "$(mock_state | jq -r ".users[\"advanced-acme\"].desc")" = someone ] && grep -q "^user=certbot$" "$V/secrets/dsm.conf"' "$r"
curl -s "http://127.0.0.1:${MOCK_PORT}/_set?deluser=advanced-acme&otp_enforced=1" >/dev/null
r="$(cgi action=dsm_create_service "user=certbot" "pass=s3cret pass&=")"
check "enforced 2-step verification -> dsm_svc_otp with DSM code, account rolled back" '[ "$(jq -r .error <<<"$r")" = dsm_svc_otp ] && [ "$(jq -r .code <<<"$r")" = 406 ] && [ "$(mock_state | jq -r ".users[\"advanced-acme\"]")" = null ]' "$r"
curl -s "http://127.0.0.1:${MOCK_PORT}/_set?otp_enforced=0" >/dev/null
r="$(cgi action=dsm_create_service user=otpuser pass=pw otp=123456)"
check "service account created via a 2FA admin, admin device not registered" '[ "$(jq -r .ok <<<"$r")" = true ] && [ "$(jq -r .managed <<<"$r")" = true ] && [ "$(mock_state | jq -r ".logins | map(select(.account==\"otpuser\")) | .[-1].device_name")" = null ] && ! grep -q "^device_id=" "$V/secrets/dsm.conf"' "$r"
check "service account is admin with a long random password, own password not stored" '[ "$(mock_state | jq -r ".users[\"advanced-acme\"] | \"\(.admin) \(.desc) \(.pwlen >= 30)\"")" = "true Advanced ACME true" ] && grep -q "^user=advanced-acme$" "$V/secrets/dsm.conf" && grep -q "^managed=1$" "$V/secrets/dsm.conf" && ! grep -q "^pass=$(printf pw | base64)$" "$V/secrets/dsm.conf"' "$(mock_state)"
pw1="$(grep "^pass=" "$V/secrets/dsm.conf")"
r="$(cgi action=dsm_create_service "user=certbot" "pass=s3cret pass&=")"
check "running again resets the password of our account" '[ "$(jq -r .ok <<<"$r")" = true ] && [ "$(grep "^pass=" "$V/secrets/dsm.conf")" != "$pw1" ]' "$r"
curl -s "http://127.0.0.1:${MOCK_PORT}/_set?password_must_change=1" >/dev/null
r="$(cgi action=dsm_create_service "user=certbot" "pass=s3cret pass&=")"
check "policy \"change password at first sign-in\": the account sets a new password itself" '[ "$(jq -r .ok <<<"$r")" = true ] && [ "$(jq -r ".dsm.data.certificates[0].id" <<<"$r")" = def01 ]' "$r"
curl -s "http://127.0.0.1:${MOCK_PORT}/_set?password_must_change=0" >/dev/null
r="$(cgi action=dsm_check)"
st="$(cgi action=status)"
check "stored service account signs in, status shows it as managed" '[ "$(jq -r .ok <<<"$r")" = true ] && [ "$(jq -r .dsm.managed <<<"$st")" = true ] && [ "$(jq -r .dsm.user <<<"$st")" = advanced-acme ]' "$r $st"
r="$(cgi action=dsm_forget)"
check "forgetting deletes the service account from DSM" '[ "$(jq -r .removed <<<"$r")" = true ] && [ "$(mock_state | jq -r ".users[\"advanced-acme\"]")" = null ] && [ ! -f "$V/secrets/dsm.conf" ]' "$r"
cgi action=dsm_create_service "user=certbot" "pass=s3cret pass&=" >/dev/null
r="$(cgi action=dsm_check "user=certbot" "pass=s3cret pass&=")"
check "switching to an existing account deletes the service account" '[ "$(jq -r .ok <<<"$r")" = true ] && [ "$(mock_state | jq -r ".users[\"advanced-acme\"]")" = null ] && ! grep -q "^managed=" "$V/secrets/dsm.conf"' "$r"

echo "== ACME account with External Account Binding"
r="$(cgi action=register server="$PEBBLE_DIR")"
j="$(wait_job "$(jq -r .job <<<"$r")")"
check "registration without EAB fails on an EAB-only CA" '[ "$(jq -r .rc <<<"$j")" != 0 ] && grep -qi "externalAccountRequired\|eab" <<<"$(jq -r .log <<<"$j")"' "$(jq -r .log <<<"$j")"
r="$(cgi action=register server="$PEBBLE_DIR" eab_kid=kid-1 eab_hmac=zWNDZM6eQGHWpSRTPal5eIUYFTu7EajVIoguysqZ9wG44nMEtx3MUAsUDkMTQ12W)"
j="$(wait_job "$(jq -r .job <<<"$r")")"
check "registration with EAB succeeds" '[ "$(jq -r .rc <<<"$j")" = 0 ]' "$(jq -r .log <<<"$j")"
check "EAB data only in private files" '[ -z "$(grep -rl zWNDZM6eQGHWpSRTPal5eIUYFTu7EajVIoguysqZ9wG44nMEtx3MUAsUDkMTQ12W "$V" | grep -v "/ca.conf$")" ] && [ "$(stat -c %a "$V")" = 700 ] && [ "$(stat -c %a "$V"/acme/ca/localhost/dir/ca.conf)" = 600 ]'
r="$(cgi action=accounts)"
check "account listed (acme.sh keys by host and path)" '[ "$(jq -r ".accounts[0]" <<<"$r")" = "https://localhost/dir" ]' "$r"

echo "== Issue certificate (DNS-01, wildcard) and install in DSM"
r="$(cgi action=issue server="$PEBBLE_DIR" plugin=dns_evil keylength=2048 provider=custom domains=nas.example.test)"
check "unknown DNS plugin rejected" '[ "$(jq -r .error <<<"$r")" = invalid_plugin ]' "$r"
r="$(cgi action=issue server="$PEBBLE_DIR" plugin=dns_pebble keylength=2048 provider=custom "domains=nas.example.test;rm -rf /")"
check "invalid domain rejected" '[ "$(jq -r .error <<<"$r")" = invalid_domain ]' "$r"
r="$(cgi action=issue server="$PEBBLE_DIR" plugin=dns_pebble keylength=2048 provider=custom domains=nas.example.test env_PATH=/tmp)"
check "foreign environment variable rejected" '[ "$(jq -r .error <<<"$r")" = invalid_dns_option ]' "$r"
r="$(cgi action=issue server="$PEBBLE_DIR" plugin=dns_pebble keylength=2048 provider=ionos "dsm_desc=NAS (ACME)" \
  "domains=nas.example.test
*.example.test" env_PEBBLE_CHALL_URL=http://127.0.0.1:8055)"
j="$(wait_job "$(jq -r .job <<<"$r")")"
log="$(jq -r .log <<<"$j")"
check "issue job succeeds" '[ "$(jq -r .rc <<<"$j")" = 0 ] && grep -q "^@@DONE" <<<"$log"' "$log"
st="$(mock_state)"
check "certificate imported into DSM with chosen name" '[ "$(jq -r ".imports[-1].desc" <<<"$st")" = "NAS (ACME)" ] && [ "$(jq -r ".imports[-1].has_key" <<<"$st")" = true ] && [ "$(jq -r ".imports[-1].has_cert" <<<"$st")" = true ]' "$st"
conf="$V/acme/nas.example.test/nas.example.test.conf"
check "renewal scheduled relative to expiry (--days -30)" 'grep -q "^Le_RenewalDays=.-30.$" "$conf"' "$(cat "$conf" 2>/dev/null)"
check "DSM password not copied into domain config" '! grep -q "SYNO_PASSWORD\|SYNO_USERNAME" "$conf"' "$(grep SYNO "$conf")"
check "deploy hook saved for renewals" 'grep -q "^Le_DeployHook=.advanced_acme_dsm" "$conf"'
check "DNS credentials of the issue stored for renewals" 'grep -qx "SAVED_PEBBLE_CHALL_URL=.http://127.0.0.1:8055." "$V/acme/account.conf"' "$(cat "$V/acme/account.conf")"
r="$(cgi action=certs)"
c="$(jq '.certs[0]' <<<"$r")"
na="$(jq -r '.not_after // 0' <<<"$c")"
nr="$(jq -r '.next_renew // 0' <<<"$c")"
days=$(( (na - $(date +%s)) / 86400 ))
check "certificate listed with SAN wildcard" '[ "$(jq -c .alt <<<"$c")" = "[\"*.example.test\"]" ] && [ "$(jq -r .deploy_status <<<"$c")" = ok ]' "$c"
# Renewal is pinned to 30 days before expiry; the CA may pull it forward
# through ARI (Pebble suggests a window at about two thirds of the lifetime).
check "180-day validity, renewal at least 30 days before expiry" '[ "$days" -ge 178 ] && [ $(( (na - nr) / 86400 )) -ge 30 ] && [ "$nr" -gt "$(jq -r .created <<<"$c")" ]' "$c"

echo "== Replace DSM default certificate"
r="$(cgi action=set_target id=nas.example.test dsm_desc=)"
r="$(cgi action=deploy id=nas.example.test)"
j="$(wait_job "$(jq -r .job <<<"$r")")"
st="$(mock_state)"
check "default certificate replaced in place" '[ "$(jq -r .rc <<<"$j")" = 0 ] && [ "$(jq -r ".imports[-1].id" <<<"$st")" = def01 ] && [ "$(jq -r ".imports[-1].as_default" <<<"$st")" = true ]' "$(jq -r .log <<<"$j"; jq -c ".imports[-1]" <<<"$st")"

echo "== Deploy with stored 2FA device token"
cgi action=dsm_check user=otpuser pass=pw otp=123456 >/dev/null
r="$(cgi action=deploy id=nas.example.test)"
j="$(wait_job "$(jq -r .job <<<"$r")")"
st="$(mock_state)"
check "hook signs in with device token, no OTP prompt" '[ "$(jq -r .rc <<<"$j")" = 0 ] && [ "$(jq -r ".logins[-1].device_id" <<<"$st")" = dev-1 ]' "$(jq -r .log <<<"$j")"
cgi action=dsm_check "user=certbot" "pass=s3cret pass&=" >/dev/null

echo "== Renewal"
n="$(mock_state | jq '.imports | length')"
r="$(cgi action=renew id=nas.example.test)"
j="$(wait_job "$(jq -r .job <<<"$r")")"
check "forced renewal re-deploys automatically" '[ "$(jq -r .rc <<<"$j")" = 0 ] && [ "$(mock_state | jq ".imports | length")" -gt "$n" ]' "$(jq -r .log <<<"$j")"
out="$("$T/bin/advanced-acme" cron 2>&1)"
check "scheduled run (cron) succeeds, nothing due" '[ $? = 0 ] && grep -q "Skipped\|Skip" <<<"$out"' "$out"
check "last cron run recorded" '[ "$(jq -r .last_cron_rc <<<"$(cgi action=status)")" = 0 ]'

echo "== Expert console"
r="$(cgi action=expert "args=--list")"
j="$(wait_job "$(jq -r .job <<<"$r")")"
check "acme.sh --list runs" '[ "$(jq -r .rc <<<"$j")" = 0 ] && grep -q nas.example.test <<<"$(jq -r .log <<<"$j")"' "$(jq -r .log <<<"$j")"
r="$(cgi action=expert "args=--upgrade")"
check "--upgrade blocked" '[ "$(jq -r .error <<<"$r")" = expert_option_blocked ]' "$r"
r="$(cgi action=expert "args=--home
/tmp")"
check "--home blocked" '[ "$(jq -r .error <<<"$r")" = expert_option_blocked ]' "$r"
r="$(cgi action=jobs)"
check "job history listed" '[ "$(jq ".jobs | length" <<<"$r")" -ge 5 ]' "$r"

echo "== Service control"
export SYNOPKG_PKGDEST="$T" SYNOPKG_PKGVAR="$V"
package/scripts/start-stop-status start
sleep 1
package/scripts/start-stop-status status
check "service starts" '[ $? = 0 ] && [ "$(jq -r .service_running <<<"$(cgi action=status)")" = true ]'
package/scripts/start-stop-status stop
package/scripts/start-stop-status status
check "service stops" '[ $? = 3 ]'

echo "== acme.sh updates"
r="$(cgi action=acme_check)"
check "update check finds newer release" '[ "$(jq -r .latest <<<"$r")" = 3.1.99 ] && [ "$(jq -r .update_available <<<"$r")" = true ]' "$r"
r="$(cgi action=acme_update "tag=1.0;rm")"
check "invalid version tag rejected" '[ "$(jq -r .error <<<"$r")" = invalid_tag ]' "$r"
r="$(cgi action=acme_update tag=3.1.98)"
j="$(wait_job "$(jq -r .job <<<"$r")")"
check "broken release archive is refused, bundled stays active" '[ "$(jq -r .rc <<<"$j")" != 0 ] && grep -q "does not look like acme.sh 3.1.98" <<<"$(jq -r .log <<<"$j")" && [ "$(jq -r .acme.updated <<<"$(cgi action=status)")" = false ] && [ ! -d "$V/acme-sh" ]' "$(jq -r .log <<<"$j")"
r="$(cgi action=acme_update tag=3.1.97)"
j="$(wait_job "$(jq -r .job <<<"$r")")"
check "release without a DNS plugin in use is refused" '[ "$(jq -r .rc <<<"$j")" != 0 ] && grep -q "no longer contains DNS plugins used by your certificates: dns_pebble" <<<"$(jq -r .log <<<"$j")" && [ ! -d "$V/acme-sh" ]' "$(jq -r .log <<<"$j")"
r="$(cgi action=acme_update tag=3.1.99)"
j="$(wait_job "$(jq -r .job <<<"$r")")"
st="$(cgi action=status)"
check "update installs newer acme.sh next to the bundled one" '[ "$(jq -r .rc <<<"$j")" = 0 ] && [ "$(jq -r .acme.active <<<"$st")" = 3.1.99 ] && [ "$(jq -r .acme.bundled <<<"$st")" = "$BUNDLED_VER" ] && [ "$(jq -r .acme.updated <<<"$st")" = true ] && [ -f "$V/acme-sh/deploy/advanced_acme_dsm.sh" ]' "$(jq -r .log <<<"$j")"
check "updated acme.sh gets the longer certificate polling too" 'grep -q "_MAX_CERT_RETRY=\"\${MAX_CERT_RETRY_TIMES:-30}\"" "$V/acme-sh/acme.sh"'
# The bundled copy is the vendored release plus src/lib/acmepatch.sh.
cp vendor/acme.sh/acme.sh "$W/acme-expected.sh"
bash -c '. src/lib/acmepatch.sh; acme_patch "$1"' _ "$W/acme-expected.sh"
check "bundled acme.sh untouched by the update" 'cmp -s "$T/acme.sh/acme.sh" "$W/acme-expected.sh"'
n="$(mock_state | jq '.imports | length')"
r="$(cgi action=renew id=nas.example.test)"
j="$(wait_job "$(jq -r .job <<<"$r")")"
check "renewal and DSM install work with the updated acme.sh" '[ "$(jq -r .rc <<<"$j")" = 0 ] && [ "$(mock_state | jq ".imports | length")" -gt "$n" ] && grep -q "v3.1.99\|3.1.99" <<<"$(cgi action=expert args=--version >/dev/null; "$T/bin/advanced-acme" acme --version)"' "$(jq -r .log <<<"$j")"
r="$(cgi action=acme_update tag=3.1.99)"
j="$(wait_job "$(jq -r .job <<<"$r")")"
check "same version again is a no-op" '[ "$(jq -r .rc <<<"$j")" = 0 ] && grep -q "@@INFO up_to_date" <<<"$(jq -r .log <<<"$j")"' "$(jq -r .log <<<"$j")"
r="$(cgi action=acme_revert)"
check "revert returns to the bundled acme.sh" '[ "$(jq -r .version <<<"$r")" = "$BUNDLED_VER" ] && [ "$(jq -r .acme.updated <<<"$(cgi action=status)")" = false ] && [ ! -d "$V/acme-sh" ]' "$r"
out="$("$T/bin/advanced-acme" acme-update 2>&1)"
check "CLI update installs the latest release" '[ $? = 0 ] && [ "$(jq -r .acme.active <<<"$(cgi action=status)")" = 3.1.99 ]' "$out"
"$T/bin/advanced-acme" acme-revert >/dev/null
cgi action=settings_set key=acme_auto_update value=1 >/dev/null
due() { bash -c '. "$AACME_TARGET/lib/all.sh"; acme_auto_update_due'; }
check "auto update due once enabled" 'due'
printf 'auto_checked=%s\n' "$(date +%s)" >>"$V/acme_update.conf"
check "auto update not due again within a day" '! due'
cgi action=settings_set key=acme_auto_update value=0 >/dev/null
check "auto update off" '! due'
# Builds such as SynoCommunity's update acme.sh only with the package.
"$T/bin/advanced-acme" acme-update >/dev/null 2>&1
echo "acme_updates=0" >"$T/share/build.conf"
st="$(cgi action=status)"
r1="$(cgi action=acme_check)"
r2="$(cgi action=acme_update tag=3.1.99)"
check "build without acme.sh updates: bundled acme.sh only, update actions refused" '[ "$(jq -r .acme.updates <<<"$st")" = false ] && [ "$(jq -r .acme.active <<<"$st")" = "$BUNDLED_VER" ] && [ "$(jq -r .error <<<"$r1")" = acme_update_disabled ] && [ "$(jq -r .error <<<"$r2")" = acme_update_disabled ]' "$st $r1 $r2"
sed -i '/^auto_checked=/d' "$V/acme_update.conf"
cgi action=settings_set key=acme_auto_update value=1 >/dev/null
check "no automatic acme.sh updates in such a build" '! due'
cgi action=settings_set key=acme_auto_update value=0 >/dev/null
echo "acme_updates=1" >"$T/share/build.conf"
check "acme.sh updates available again" '[ "$(jq -r .acme.updates <<<"$(cgi action=status)")" = true ]'
"$T/bin/advanced-acme" acme-revert >/dev/null

echo "== ECDSA certificate"
r="$(cgi action=issue server="$PEBBLE_DIR" plugin=dns_pebble keylength=ec-256 provider=custom domains=ecc.example.test)"
j="$(wait_job "$(jq -r .job <<<"$r")")"
check "ECDSA certificate issued and installed" '[ "$(jq -r .rc <<<"$j")" = 0 ]' "$(jq -r .log <<<"$j")"
r="$(cgi action=deploy id=ecc.example.test_ecc)"
j="$(wait_job "$(jq -r .job <<<"$r")")"
check "ECDSA certificate re-deploy by id" '[ "$(jq -r .rc <<<"$j")" = 0 ] && [ "$(mock_state | jq -r ".imports[-1].desc")" = ecc.example.test ]' "$(jq -r .log <<<"$j")"
out="$("$T/bin/advanced-acme" acme --list 2>&1)"
check "CLI passthrough lists both certificates" 'grep -q ecc.example.test <<<"$out" && grep -q nas.example.test <<<"$out"' "$out"
out="$("$T/bin/advanced-acme" acme --upgrade 2>&1)"
check "CLI blocks --upgrade" '[ $? != 0 ] && grep -q "managed by the Advanced ACME package" <<<"$out"' "$out"
cgi action=remove id=ecc.example.test_ecc >/dev/null

echo "== DSM task (2-step verification enforced for all administrators)"
curl -s "http://127.0.0.1:${MOCK_PORT}/_set?otp_enforced=1" >/dev/null
# A scheduled task of the same name, as script version 1 created it.
curl -s "http://127.0.0.1:${MOCK_PORT}/_set?addtask=Advanced%20ACME" >/dev/null
event_tasks() { mock_state | jq '[.tasks[] | select(.event)] | length'; }
task_pid() { sed -n 's/^pid=//p' "$W/run/heartbeat" 2>/dev/null; }
# running PID: the process exists and has not ended (the mock, as its parent,
# collects ended processes only later)
running() { [ -n "$1" ] && ps -o stat= -p "$1" 2>/dev/null | grep -qv "^Z"; }
r="$(cgi action=dsm_create_task user=certbot pass=wrong)"
check "task needs a valid administrator sign-in" '[ "$(jq -r .error <<<"$r")" = dsm_auth_400 ] && [ "$(event_tasks)" = 0 ]' "$r"
r="$(cgi action=dsm_create_task "user=certbot" "pass=s3cret pass&=")"
st="$(mock_state)"
check "boot-up task created as root with password confirmation, started, replaces the account and the minute task" '[ "$(jq -r .ok <<<"$r")" = true ] && [ "$(jq -r .mode <<<"$r")" = task ] && [ "$(jq -r "[.tasks[] | select(.event)][0] | \"\(.event) \(.owner) \(.type)\"" <<<"$st")" = "bootup root script" ] && [ "$(jq "[.tasks[] | select(.schedule)] | length" <<<"$st")" = 0 ] && [ ! -f "$V/secrets/dsm.conf" ] && grep -q "^version=2$" "$W/run/heartbeat"' "$r $st"
script="$(jq -r "[.tasks[] | select(.event)][0].script" <<<"$st")"
check "task script carries this NAS's paths and runs no package files" 'grep -q "^Q=.$V/dsm-task.$" <<<"$script" && ! grep -qE "advanced-acme |lib/|acme\.sh" <<<"$script"' "$script"
check "certificate list of the first run returned" '[ "$(jq -r ".dsm.data.certificates[0].id" <<<"$r")" = def01 ]' "$r"
r="$(cgi action=status)"
check "status shows the DSM task" '[ "$(jq -r .dsm.mode <<<"$r")" = task ] && [ "$(jq -r .dsm.configured <<<"$r")" = true ] && [ "$(jq -r ".dsm.task.last_run > 0" <<<"$r")" = true ] && [ "$(jq -r ".dsm.task.version == .dsm.task.current_version" <<<"$r")" = true ]' "$r"
pid1="$(task_pid)"
sleep 3
check "the task stays in the background" 'running "$pid1"' "$pid1"
# While there is nothing to do, nothing is written to the package folder (on
# the disks); results and signs of life go to the run folder (RAM).
touch "$W/idle"
sleep 4
check "idle task writes nothing to the package folder" '[ -z "$(find "$V" -newer "$W/idle")" ]' "$(find "$V" -newer "$W/idle")"
curl -s "http://127.0.0.1:${MOCK_PORT}/_set?addcert=Added%20in%20DSM" >/dev/null
r="$(cgi action=dsm_check)"
check "certificate list read anew on request" '[ "$(jq -r "[.dsm.data.certificates[].desc] | index(\"Added in DSM\") != null" <<<"$r")" = true ]' "$r"
n_imports="$(mock_state | jq ".imports | length")"
r="$(cgi action=deploy id=nas.example.test)"
j="$(wait_job "$(jq -r .job <<<"$r")")"
st="$(mock_state)"
check "certificate installed by the root task into the default certificate" '[ "$(jq -r .rc <<<"$j")" = 0 ] && [ "$(jq ".imports | length" <<<"$st")" -gt "$n_imports" ] && [ "$(jq -r ".imports[-1].via" <<<"$st")" = task ] && [ "$(jq -r ".imports[-1].id" <<<"$st")" = def01 ] && [ "$(jq -r ".imports[-1].has_key and .imports[-1].has_chain" <<<"$st")" = true ]' "$(jq -r .log <<<"$j")"
check "request picked up and logged" '[ -z "$(ls "$V/dsm-task/queue")" ] && grep -q "\"dsm_task_installed\"" "$V/logs/activity.log"' "$(ls "$V/dsm-task/queue")"
# Wildcard as main name: acme.sh keeps it in "*.example.test", the task only
# accepts plain names. A request stuck with the old name is dropped.
: >"$V/dsm-task/queue/*.stuck.example.test.req"
r="$(cgi action=issue server="$PEBBLE_DIR" plugin=dns_pebble keylength=2048 provider=ionos "dsm_desc=Wild (task)" \
  "domains=*.example.test
example.test" env_PEBBLE_CHALL_URL=http://127.0.0.1:8055)"
j="$(wait_job "$(jq -r .job <<<"$r")")"
st="$(mock_state)"
check "wildcard certificate (wildcard as main name) installed by the root task" '[ "$(jq -r .rc <<<"$j")" = 0 ] && [ "$(jq -r ".imports[-1].desc" <<<"$st")" = "Wild (task)" ] && [ "$(jq -r ".imports[-1].via" <<<"$st")" = task ] && grep -q "The DSM task installed the certificate" <<<"$(jq -r .log <<<"$j")"' "$(jq -r .log <<<"$j")"
check "stuck request with an unusable name removed" '[ ! -e "$V/dsm-task/queue/*.stuck.example.test.req" ]' "$(ls "$V/dsm-task/queue")"
cgi action=remove "id=*.example.test" >/dev/null
printf 'nonce=abc123\ndomain=bad.example.test\ndesc_b64=\nkey_b64=%s\ncert_b64=%s\nchain_b64=\n' "$(printf 'not a key' | base64)" "$(printf 'not a cert' | base64)" >"$V/dsm-task/queue/bad.example.test.req"
for _ in $(seq 1 20); do [ -f "$W/run/bad.example.test.result" ] && break; sleep 1; done
check "root task rejects an invalid certificate" 'grep -q "^status=fail$" "$W/run/bad.example.test.result" && grep -q "^code=invalid_cert$" "$W/run/bad.example.test.result"' "$(cat "$W/run/bad.example.test.result" 2>/dev/null)"
rm -f "$V/dsm-task/queue/bad.example.test.req"
# Setting the task up again (e.g. a newer script): the running instance ends,
# the new one takes over.
r="$(cgi action=dsm_create_task "user=certbot" "pass=s3cret pass&=")"
pid2="$(task_pid)"
check "task set up again: old instance ended, new one running, still one task" '[ "$(jq -r .ok <<<"$r")" = true ] && [ -n "$pid2" ] && [ "$pid2" != "$pid1" ] && ! running "$pid1" && running "$pid2" && [ "$(event_tasks)" = 1 ]' "$r pid1=$pid1 pid2=$pid2"
r="$(cgi action=dsm_task_remove)"
for _ in $(seq 1 20); do [ "$(event_tasks)" = 0 ] && break; sleep 1; done
sleep 2
r="$(cgi action=status)"
check "removing: the task deletes itself and ends, logged" '[ "$(event_tasks)" = 0 ] && ! running "$pid2" && [ "$(jq -r .dsm.mode <<<"$r")" = none ] && grep -q "\"dsm_task_removed\"" "$V/logs/activity.log"' "tasks=$(event_tasks) $(ps -o pid,stat,args -p "$pid2" 2>/dev/null | tail -n +2) $r"
# Uninstalled with the data kept: the package folder stays missing, the task
# deletes itself and ends. After the reinstall it must not count as set up.
cgi action=dsm_create_task "user=certbot" "pass=s3cret pass&=" >/dev/null
pid3="$(task_pid)"
rmdir "$W/pkgdir"
for _ in $(seq 1 20); do [ "$(event_tasks)" = 0 ] && break; sleep 1; done
sleep 2
mkdir "$W/pkgdir"
r="$(cgi action=status)"
check "task deletes itself when the package stays uninstalled, no longer set up" '[ "$(event_tasks)" = 0 ] && ! running "$pid3" && [ "$(jq -r .dsm.mode <<<"$r")" = none ] && [ ! -f "$V/dsm-task/task.conf" ] && [ "$(grep -c "\"dsm_task_removed\"" "$V/logs/activity.log")" = 2 ]' "tasks=$(event_tasks) $(ps -o pid,stat,args -p "$pid3" 2>/dev/null | tail -n +2) $r"
r="$(cgi action=activity)"
check "activity log lists the steps in order" '[ "$(jq -r "[.events[].e] | map(select(startswith(\"dsm_task\"))) | join(\",\")" <<<"$r")" = "dsm_task_created,dsm_task_installed,dsm_task_installed,dsm_task_updated,dsm_task_remove_requested,dsm_task_removed,dsm_task_created,dsm_task_removed" ]' "$r"
curl -s "http://127.0.0.1:${MOCK_PORT}/_set?otp_enforced=0" >/dev/null
cgi action=dsm_check "user=certbot" "pass=s3cret pass&=" >/dev/null

echo "== Interrupted job"
jid="$(bash -c '. "$AACME_TARGET/lib/all.sh"; job_prepare issue reap.example.test')"
echo running >"$V/jobs/$jid.state"
bash -c 'exit 0' & dead=$!; wait "$dead"
echo "$dead" >"$V/jobs/$jid.pid"
r="$(cgi action=job id="$jid")"
check "job whose process died is reported as failed" '[ "$(jq -r .state <<<"$r")" = done ] && [ "$(jq -r .rc <<<"$r")" = 1 ] && grep -q "@@FAIL interrupted" <<<"$(jq -r .log <<<"$r")"' "$r"
old="$(bash -c '. "$AACME_TARGET/lib/all.sh"; job_prepare issue legacy.example.test')"
echo running >"$V/jobs/$old.state"
r="$(cgi action=job id="$old")"
check "recent job without pid file (early beta builds) keeps running" '[ "$(jq -r .state <<<"$r")" = running ]' "$r"
sed -i "s/^started=.*/started=$(($(date +%s) - 3 * 3600))/" "$V/jobs/$old.info"
r="$(cgi action=job id="$old")"
check "stale job without pid file is reported as failed" '[ "$(jq -r .state <<<"$r")" = done ] && [ "$(jq -r .rc <<<"$r")" = 1 ]' "$r"

echo "== Remove"
r="$(cgi action=remove id=nas.example.test)"
check "certificate removed from management" '[ "$(jq -r .ok <<<"$r")" = true ] && [ "$(jq ".certs | length" <<<"$(cgi action=certs)")" = 0 ]' "$r"
r="$(cgi action=remove "id=../../etc")"
check "path traversal in id rejected" '[ "$(jq -r .error <<<"$r")" = cert_not_found ]' "$r"

echo "== Package name"
pkgname() { env -u SYNOPKG_PKGNAME "$@" bash -c '. "$AACME_TARGET/lib/common.sh"; printf %s "$AACME_PKG"'; }
mkdir -p "$W/@appstore"
cp -a "$T" "$W/@appstore/advanced-acme"
check "package name defaults to AdvancedACME outside DSM" '[ "$(pkgname)" = AdvancedACME ]'
check "package name follows the install folder (@appstore/<name>)" '[ "$(pkgname AACME_TARGET="$W/@appstore/advanced-acme")" = advanced-acme ]'
check "package name from DSM wins" '[ "$(pkgname SYNOPKG_PKGNAME=other)" = other ]'
rm -rf "$W/@appstore"

echo "== Uninstall with \"delete data\""
cgi action=dsm_create_service "user=certbot" "pass=s3cret pass&=" >/dev/null
SYNOPKG_PKG_STATUS=UPGRADE wizard_delete_data=true sh "$ROOT/package/scripts/preuninst"
check "upgrade keeps data and the service account" '[ -f "$V/secrets/dsm.conf" ] && [ "$(mock_state | jq -r ".users[\"advanced-acme\"].admin")" = true ]'
# Like on DSM, /var/packages/<pkg>/var is a symlink to @appdata.
ln -sfn "$V" "$W/var-link"
SYNOPKG_PKG_STATUS=UNINSTALL wizard_delete_data=true SYNOPKG_PKGVAR="$W/var-link" sh "$ROOT/package/scripts/preuninst"
check "uninstall deletes the service account and all data (through the var symlink)" '[ "$(mock_state | jq -r ".users[\"advanced-acme\"]")" = null ] && [ -z "$(ls -A "$V")" ]' "$(ls -A "$V")"

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" = 0 ]

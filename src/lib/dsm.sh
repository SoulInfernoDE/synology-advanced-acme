#!/bin/bash
# DSM Web API access used to verify the stored DSM account and to read the
# certificate list. The actual certificate upload is done by acme.sh's
# synology_dsm deploy hook through our advanced_acme_dsm wrapper.

DSM_CONF="${AACME_SECRETS}/dsm.conf"

# Service account the wizard creates in DSM. The description marks it as ours.
SVC_NAME="advanced-acme"
SVC_DESC="Advanced ACME"

synoinfo_get() {
  sed -n "s/^$1=\"\{0,1\}\([^\"]*\)\"\{0,1\}\$/\1/p" "${AACME_SYNOINFO:-/etc/synoinfo.conf}" 2>/dev/null | head -n1
}

# dsm_detect: sets DSM_SCHEME, DSM_HOST, DSM_PORT and DSM_INSECURE.
# Prefers plain HTTP on localhost; falls back to HTTPS when DSM redirects HTTP.
dsm_detect() {
  local http_port https_port resp
  DSM_HOST="$(setting dsm_host)"
  DSM_HOST="${DSM_HOST:-localhost}"
  DSM_SCHEME="$(setting dsm_scheme)"
  DSM_PORT="$(setting dsm_port)"
  DSM_INSECURE=""
  if [ -n "$DSM_SCHEME" ] && [ -n "$DSM_PORT" ]; then
    [ "$DSM_SCHEME" = "https" ] && [ "$DSM_HOST" = "localhost" ] && DSM_INSECURE=1
    return 0
  fi
  http_port="$(synoinfo_get admin_port)"
  https_port="$(synoinfo_get secure_admin_port)"
  http_port="${http_port:-5000}"
  https_port="${https_port:-5001}"
  resp="$(curl -s --max-time 10 "http://${DSM_HOST}:${http_port}/webapi/query.cgi?api=SYNO.API.Info&version=1&method=query&query=SYNO.API.Auth" 2>/dev/null)"
  if printf '%s' "$resp" | grep -q '"SYNO.API.Auth"'; then
    DSM_SCHEME=http
    DSM_PORT="$http_port"
  else
    DSM_SCHEME=https
    DSM_PORT="$https_port"
    DSM_INSECURE=1
  fi
}

# DSM refuses user management (SYNO.Core.User*) in sessions opened from the
# loopback address, even for administrators. Sign-ins with DSM_LAN=1 therefore
# go to the NAS's own network address.
dsm_use_lan() {
  local ip ipcmd
  case "$DSM_HOST" in localhost | 127.0.0.1 | ::1) ;; *) return 0 ;; esac
  ip="${AACME_DSM_LAN_HOST:-}"
  if [ -z "$ip" ]; then
    ipcmd="$(command -v ip 2>/dev/null || echo /sbin/ip)"
    ip="$("$ipcmd" -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
  fi
  [ -n "$ip" ] || return 0
  DSM_HOST="$ip"
  # Still this NAS, whose certificate does not name the address.
  [ "$DSM_SCHEME" = https ] && DSM_INSECURE=1
  return 0
}

dsm_curl() {
  local opts=(-s --max-time 30)
  [ -n "$DSM_INSECURE" ] && opts+=(-k)
  curl "${opts[@]}" "$@"
}

dsm_base() { printf '%s://%s:%s' "$DSM_SCHEME" "$DSM_HOST" "$DSM_PORT"; }

json_field() {
  # Minimal extractor for flat string/number fields in DSM responses.
  printf '%s' "$1" | sed -n "s/.*\"$2\" *: *\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" | head -n1
}

dsm_error_code() {
  printf '%s' "$1" | grep -o '"error" *: *{[^}]*' | grep -o '"code" *: *[0-9]*' | grep -o '[0-9]*$' | head -n1
}

# dsm_login USER PASS [OTP]: sets DSM_SID, DSM_SYNOTOKEN, DSM_NEW_DEVICE_ID or
# DSM_ERR (DSM error code, or "unreachable"). With DSM_NO_DEVICE=1 the stored
# device token is not used and the NAS is not registered as a trusted device
# (one-time sign-ins with somebody else's account).
dsm_login() {
  local user="$1" pass="$2" otp="$3" info path ver resp code device_id device_name id_prop
  DSM_SID=""
  DSM_SYNOTOKEN=""
  DSM_ERR=""
  DSM_NEW_DEVICE_ID=""
  dsm_detect
  [ -n "${DSM_LAN:-}" ] && dsm_use_lan
  info="$(dsm_curl "$(dsm_base)/webapi/query.cgi?api=SYNO.API.Info&version=1&method=query&query=SYNO.API.Auth")"
  path="$(printf '%s' "$info" | grep -o '"path" *: *"[^"]*"' | head -n1 | sed 's/.*"\([^"]*\)"$/\1/')"
  ver="$(printf '%s' "$info" | grep -o '"maxVersion" *: *[0-9]*' | head -n1 | grep -o '[0-9]*$')"
  if [ -z "$path" ] || [ -z "$ver" ]; then
    DSM_ERR="unreachable"
    return 1
  fi
  device_id="$(kv_get "$DSM_CONF" device_id)"
  device_name="$(setting dsm_device_name)"
  local args=(--data-urlencode "api=SYNO.API.Auth" --data-urlencode "version=${ver}"
    --data-urlencode "method=login" --data-urlencode "format=sid"
    --data-urlencode "account=${user}" --data-urlencode "passwd=${pass}"
    --data-urlencode "enable_syno_token=yes")
  if [ -n "$otp" ] && [ -n "${DSM_NO_DEVICE:-}" ]; then
    args+=(--data-urlencode "otp_code=${otp}")
  elif [ -n "$otp" ]; then
    args+=(--data-urlencode "enable_device_token=yes" --data-urlencode "device_name=${device_name}"
      --data-urlencode "otp_code=${otp}")
  elif [ -n "$device_id" ] && [ -z "${DSM_NO_DEVICE:-}" ]; then
    args+=(--data-urlencode "device_name=${device_name}" --data-urlencode "device_id=${device_id}")
  fi
  resp="$(dsm_curl "${args[@]}" "$(dsm_base)/webapi/${path}")"
  code="$(dsm_error_code "$resp")"
  if [ -n "$code" ]; then
    # A stale device token looks like "OTP required"; report it as such.
    DSM_ERR="$code"
    return 1
  fi
  DSM_SID="$(json_field "$resp" sid)"
  DSM_SYNOTOKEN="$(json_field "$resp" synotoken)"
  if [ -n "$otp" ] && [ -z "${DSM_NO_DEVICE:-}" ]; then
    id_prop=device_id
    [ "$ver" -gt 6 ] || id_prop=did
    DSM_NEW_DEVICE_ID="$(json_field "$resp" "$id_prop")"
  fi
  if [ -z "$DSM_SID" ]; then
    DSM_ERR="nosid"
    return 1
  fi
  DSM_AUTH_PATH="$path"
  DSM_AUTH_VER="$ver"
  return 0
}

dsm_logout() {
  [ -n "$DSM_SID" ] || return 0
  dsm_curl --data-urlencode "api=SYNO.API.Auth" --data-urlencode "version=${DSM_AUTH_VER:-6}" \
    --data-urlencode "method=logout" --data-urlencode "_sid=${DSM_SID}" \
    "$(dsm_base)/webapi/${DSM_AUTH_PATH:-entry.cgi}" >/dev/null 2>&1
  DSM_SID=""
}

# dsm_call API METHOD [KEY=VALUE...]: Web API call in the current session
# (version 1, or DSM_API_VERSION). Values of JSON-format APIs must be JSON
# encoded by the caller.
dsm_call() {
  local api="$1" method="$2" hdr=() args=() a
  shift 2
  [ -n "$DSM_SYNOTOKEN" ] && hdr=(-H "X-SYNO-TOKEN: ${DSM_SYNOTOKEN}")
  for a in "$@"; do args+=(--data-urlencode "$a"); done
  dsm_curl "${hdr[@]}" --data-urlencode "api=${api}" --data-urlencode "method=${method}" \
    --data-urlencode "version=${DSM_API_VERSION:-1}" --data-urlencode "_sid=${DSM_SID}" "${args[@]}" \
    "$(dsm_base)/webapi/entry.cgi"
}

dsm_ok() { printf '%s' "$1" | grep -q '^{.*"success" *: *true'; }

dsm_cert_list_raw() {
  dsm_call SYNO.Core.Certificate.CRT list
}

dsm_has_credentials() {
  [ -n "$(kv_get "$DSM_CONF" user)" ] && [ -n "$(kv_get "$DSM_CONF" pass)" ]
}

# cmd_dsm_check [USER PASS OTP]: verify credentials (given or stored), store them
# on success and print the DSM certificate list as JSON.
cmd_dsm_check() {
  local user="${1:-}" pass="${2:-}" otp="${3:-}" save=0 list code
  # DSM task: the certificate list comes from its last run.
  if [ -z "$user" ] && task_configured; then
    printf '{"ok":true,"mode":"task","user":"","dsm":{"data":%s}}' "$(task_certs_json)"
    return 0
  fi
  if [ -n "$user" ]; then
    save=1
    # New account: forget the device token of a previous account.
    [ "$user" != "$(kv_get "$DSM_CONF" user)" ] && kv_del "$DSM_CONF" device_id
  else
    user="$(kv_get "$DSM_CONF" user)"
    pass="$(b64dec "$(kv_get "$DSM_CONF" pass)")"
  fi
  if [ -z "$user" ] || [ -z "$pass" ]; then
    printf '{"ok":false,"error":"dsm_no_credentials"}'
    return 0
  fi
  if ! dsm_login "$user" "$pass" "$otp"; then
    printf '{"ok":false,"error":"dsm_auth_%s"}' "$(json_escape "$DSM_ERR")"
    return 0
  fi
  list="$(dsm_cert_list_raw)"
  code="$(dsm_error_code "$list")"
  dsm_logout
  if [ -n "$code" ]; then
    # 105: the account is not an administrator.
    printf '{"ok":false,"error":"dsm_list_%s"}' "$(json_escape "$code")"
    return 0
  fi
  local new_device="$DSM_NEW_DEVICE_ID"
  if [ "$save" = 1 ]; then
    # Switching away from the account created by Advanced ACME: delete it.
    if [ "$(kv_get "$DSM_CONF" managed)" = 1 ] && [ "$user" != "$SVC_NAME" ]; then
      dsm_remove_service
      kv_del "$DSM_CONF" managed
    fi
    touch "$DSM_CONF"
    chmod 600 "$DSM_CONF"
    kv_set "$DSM_CONF" user "$user"
    kv_set "$DSM_CONF" pass "$(b64enc "$pass")"
    activity_log dsm_account_saved user "$user"
    # An account replaces the DSM task.
    task_configured && task_remove
  fi
  [ -n "$new_device" ] && kv_set "$DSM_CONF" device_id "$new_device"
  case "$list" in
    \{*\}) ;;
    *) list='{}' ;;
  esac
  printf '{"ok":true,"user":%s,"scheme":%s,"port":%s,"dsm":%s}' \
    "$(json_str "$user")" "$(json_str "$DSM_SCHEME")" "$(json_str "$DSM_PORT")" "$list"
}

# svc_password: random password that meets the strictest DSM password rules
# (upper and lower case, digits, special characters).
svc_password() {
  local r=""
  while [ "${#r}" -lt 30 ]; do
    r+="$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')"
  done
  printf '%s-%s_Aa1' "${r:0:15}" "${r:15:15}"
}

# dsm_wait_task API RESPONSE: wait for a DSM background task (group join).
dsm_wait_task() {
  local api="$1" task i
  task="$(json_field "$2" task_id)"
  [ -n "$task" ] || return 0
  for i in $(seq 1 30); do
    dsm_call "$api" join_status "task_id=$(json_str "$task")" | grep -q '"finish" *: *true' && return 0
    sleep 1
  done
  return 1
}

# dsm_svc_fail ERROR [DSM_CODE]: undo a half-created service account and
# report ERROR. Needs the administrator session in DSM_SID.
dsm_svc_fail() {
  if [ "${1}" != dsm_svc_exists ]; then
    dsm_call SYNO.Core.User delete "name=[$(json_str "$SVC_NAME")]" >/dev/null
    activity_log dsm_account_rolled_back user "$SVC_NAME" code "${2:-$1}"
  fi
  dsm_logout
  printf '{"ok":false,"error":%s,"code":%s}' "$(json_str "$1")" "$(json_str "${2:-}")"
}

# dsm_reset_password USER OLD NEW: set a new password for an account that DSM
# asks to change it at sign-in (policy "change password at first sign-in",
# expired password), the way the DSM login page does.
dsm_reset_password() {
  local resp
  dsm_detect
  resp="$(dsm_curl --data-urlencode "api=SYNO.API.Auth" --data-urlencode "version=6" --data-urlencode "method=reset" \
    --data-urlencode "session=webui" --data-urlencode "account=$1" --data-urlencode "passwd=$2" \
    --data-urlencode "new_passwd=$3" "$(dsm_base)/webapi/${DSM_AUTH_PATH:-entry.cgi}")"
  dsm_ok "$resp" && return 0
  DSM_ERR="reset_$(dsm_error_code "$resp")"
  return 1
}

# cmd_dsm_create_service USER PASS [OTP]: sign in once with the given
# administrator, create (or reset) the account "advanced-acme" with a random
# password in the administrators group and store only that account.
cmd_dsm_create_service() {
  local admin="$1" apass="$2" otp="$3" pw resp code list adm
  if [ -z "$admin" ] || [ -z "$apass" ]; then
    printf '{"ok":false,"error":"dsm_no_credentials"}'
    return 0
  fi
  if ! DSM_LAN=1 DSM_NO_DEVICE=1 dsm_login "$admin" "$apass" "$otp"; then
    printf '{"ok":false,"error":"dsm_auth_%s"}' "$(json_escape "$DSM_ERR")"
    return 0
  fi
  pw="$(svc_password)"
  resp="$(dsm_call SYNO.Core.User get "name=$(json_str "$SVC_NAME")" 'additional=["description"]')"
  if dsm_ok "$resp"; then
    # The name exists: take it over only if Advanced ACME created it.
    [ "$(json_field "$resp" description)" = "$SVC_DESC" ] || { dsm_svc_fail dsm_svc_exists; return 0; }
    resp="$(dsm_call SYNO.Core.User set "name=$(json_str "$SVC_NAME")" "password=$(json_str "$pw")" \
      cannot_chg_passwd=true passwd_never_expire=true 'expired="normal"')"
  else
    code="$(dsm_error_code "$resp")"
    if [ "$code" = 105 ]; then
      dsm_logout
      printf '{"ok":false,"error":"dsm_list_105"}'
      return 0
    fi
    resp="$(dsm_call SYNO.Core.User create "name=$(json_str "$SVC_NAME")" "password=$(json_str "$pw")" \
      "description=$(json_str "$SVC_DESC")" 'email=""' cannot_chg_passwd=true passwd_never_expire=true \
      'expired="normal"' notify_by_email=false send_password=false)"
  fi
  if ! dsm_ok "$resp"; then
    code="$(dsm_error_code "$resp")"
    dsm_logout
    printf '{"ok":false,"error":"dsm_svc_create"}'
    return 0
  fi
  resp="$(dsm_call SYNO.Core.User.Group join "name=$(json_str "$SVC_NAME")" 'join_group=["administrators"]' 'leave_group=[]')"
  if ! dsm_ok "$resp" || ! dsm_wait_task SYNO.Core.User.Group "$resp"; then
    dsm_svc_fail dsm_svc_group
    return 0
  fi

  # Check the new account the way the deploy hook will use it (loopback).
  adm=("$DSM_SID" "$DSM_SYNOTOKEN" "$DSM_SCHEME" "$DSM_HOST" "$DSM_PORT" "$DSM_INSECURE")
  local signed_in=0 pw2
  if DSM_NO_DEVICE=1 dsm_login "$SVC_NAME" "$pw"; then
    signed_in=1
  elif [[ "$DSM_ERR" =~ ^(408|409|410)$ ]]; then
    # DSM wants a new password before the first sign-in: set another random one.
    pw2="$(svc_password)"
    if dsm_reset_password "$SVC_NAME" "$pw" "$pw2"; then
      pw="$pw2"
      activity_log dsm_account_password_renewed user "$SVC_NAME"
      DSM_NO_DEVICE=1 dsm_login "$SVC_NAME" "$pw" && signed_in=1
    fi
  fi
  if [ "$signed_in" = 1 ]; then
    list="$(dsm_cert_list_raw)"
    code="$(dsm_error_code "$list")"
    dsm_logout
    [ -n "$code" ] && DSM_ERR="list_${code}"
  fi
  DSM_SID="${adm[0]}" DSM_SYNOTOKEN="${adm[1]}" DSM_SCHEME="${adm[2]}" DSM_HOST="${adm[3]}"
  DSM_PORT="${adm[4]}" DSM_INSECURE="${adm[5]}"
  if [ -n "$DSM_ERR" ]; then
    case "$DSM_ERR" in
      403 | 406) dsm_svc_fail dsm_svc_otp "$DSM_ERR" ;;
      *) dsm_svc_fail dsm_svc_check "$DSM_ERR" ;;
    esac
    return 0
  fi
  dsm_logout

  rm -f "$DSM_CONF"
  touch "$DSM_CONF"
  chmod 600 "$DSM_CONF"
  kv_set "$DSM_CONF" user "$SVC_NAME"
  kv_set "$DSM_CONF" pass "$(b64enc "$pw")"
  kv_set "$DSM_CONF" managed 1
  activity_log dsm_account_created user "$SVC_NAME"
  task_configured && task_remove
  case "$list" in
    \{*\}) ;;
    *) list='{}' ;;
  esac
  printf '{"ok":true,"user":%s,"managed":true,"scheme":%s,"port":%s,"dsm":%s}' \
    "$(json_str "$SVC_NAME")" "$(json_str "$DSM_SCHEME")" "$(json_str "$DSM_PORT")" "$list"
}

# dsm_remove_service: the service account deletes itself (DSM allows that, so
# no administrator password is needed). Succeeds when its sign-in is refused
# afterwards.
dsm_remove_service() {
  local pass
  pass="$(b64dec "$(kv_get "$DSM_CONF" pass)")"
  [ -n "$pass" ] || return 1
  if DSM_LAN=1 DSM_NO_DEVICE=1 dsm_login "$SVC_NAME" "$pass"; then
    dsm_call SYNO.Core.User delete "name=[$(json_str "$SVC_NAME")]" >/dev/null
    # The session ends together with the account.
    DSM_SID=""
  fi
  if DSM_NO_DEVICE=1 dsm_login "$SVC_NAME" "$pass"; then
    dsm_logout
    activity_log dsm_account_remove_failed user "$SVC_NAME"
    return 1
  fi
  case "$DSM_ERR" in
    400 | 401)
      activity_log dsm_account_removed user "$SVC_NAME"
      return 0
      ;;
  esac
  activity_log dsm_account_remove_failed user "$SVC_NAME"
  return 1
}

# cmd_dsm_forget: forget the stored account; an account created by Advanced
# ACME is deleted from DSM as well.
cmd_dsm_forget() {
  local user managed=false removed=false
  user="$(kv_get "$DSM_CONF" user)"
  if [ "$(kv_get "$DSM_CONF" managed)" = 1 ]; then
    managed=true
    dsm_remove_service && removed=true
  elif [ -n "$user" ]; then
    activity_log dsm_account_forgotten user "$user"
  fi
  rm -f "$DSM_CONF"
  task_remove
  printf '{"ok":true,"user":%s,"managed":%s,"removed":%s}' "$(json_str "$user")" "$managed" "$removed"
}

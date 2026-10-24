#!/bin/bash
# JSON API for the Advanced ACME web interface.
#
# Only POST requests from logged-in DSM administrators are accepted. Requests
# must carry the "X-AACME: 1" header: browsers cannot add custom headers to
# cross-site requests, which protects the API against CSRF.

export LC_ALL=C
SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"
AACME_TARGET="${AACME_TARGET:-$(dirname "$(dirname "$SELF")")}"
# Without readlink: DSM serves this file as /webman/3rdparty/<package>/api.cgi.
if [ ! -f "${AACME_TARGET}/lib/all.sh" ]; then
  AACME_PKG="${SCRIPT_NAME#*/3rdparty/}"
  AACME_PKG="${AACME_PKG%%/*}"
  AACME_TARGET="/var/packages/${AACME_PKG:-AdvancedACME}/target"
fi

# shellcheck source=../lib/all.sh
. "${AACME_TARGET}/lib/all.sh"

AUTH_CGI="${AACME_AUTH_CGI:-/usr/syno/synoman/webman/modules/authenticate.cgi}"
LOGIN_CGI="${AACME_LOGIN_CGI:-/usr/syno/synoman/webman/login.cgi}"
GROUP_FILE="${AACME_GROUP_FILE:-/etc/group}"

respond() {
  printf 'Content-Type: application/json; charset=utf-8\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\r\n'
  printf '%s' "$1"
  exit 0
}

fail() {
  respond "{\"ok\":false,\"error\":$(json_str "$1")}"
}

deny() {
  printf 'Status: 403 Forbidden\r\nContent-Type: application/json; charset=utf-8\r\nCache-Control: no-store\r\n\r\n'
  printf '{"ok":false,"error":%s}' "$(json_str "$1")"
  exit 0
}

# --- Authentication -----------------------------------------------------------

auth_user() {
  local token="${HTTP_X_SYNO_TOKEN:-}" out
  if [ -z "$token" ]; then
    # CSRF protection may be off, or the token was not passed: ask DSM for the
    # token that belongs to this session cookie.
    out="$(REQUEST_METHOD=GET QUERY_STRING="" "$LOGIN_CGI" 2>/dev/null)"
    token="$(printf '%s' "$out" | grep -o '"SynoToken" *: *"[^"]*"' | head -n1 | sed 's/.*"\([^"]*\)"$/\1/')"
  fi
  REQUEST_METHOD=GET QUERY_STRING="SynoToken=${token}" HTTP_X_SYNO_TOKEN="$token" "$AUTH_CGI" 2>/dev/null | tr -d '\r\n'
}

is_admin() {
  local user="$1"
  [ -n "$user" ] || return 1
  if grep -E '^administrators:' "$GROUP_FILE" 2>/dev/null | cut -d: -f4 | tr ',' '\n' | grep -Fxq "$user"; then
    return 0
  fi
  id -Gn "$user" 2>/dev/null | tr ' ' '\n' | grep -Fxq administrators
}

# --- Request parsing ----------------------------------------------------------

urldecode() {
  local s="${1//+/ }" out="" c
  while [[ "$s" =~ ^([^%]*)%([0-9A-Fa-f]{2})(.*)$ ]]; do
    out+="${BASH_REMATCH[1]}"
    printf -v c "\\x${BASH_REMATCH[2]}"
    out+="$c"
    s="${BASH_REMATCH[3]}"
  done
  printf '%s' "${out}${s}"
}

declare -A P
parse_body() {
  local body="" pair key val
  local len="${CONTENT_LENGTH:-0}"
  [[ "$len" =~ ^[0-9]+$ ]] || len=0
  [ "$len" -le 1048576 ] || deny too_large
  [ "$len" -gt 0 ] && IFS= read -r -N "$len" body
  local IFS='&'
  for pair in $body; do
    key="$(urldecode "${pair%%=*}")"
    if [[ "$pair" == *=* ]]; then val="$(urldecode "${pair#*=}")"; else val=""; fi
    [[ "$key" =~ ^[A-Za-z0-9_]{1,64}$ ]] || continue
    P[$key]="$val"
  done
}

p() { printf '%s' "${P[$1]:-}"; }

single_line() { [[ "$1" != *$'\n'* && "$1" != *$'\r'* ]]; }

# --- Actions ------------------------------------------------------------------

act_issue() {
  local server plugin keylength provider desc force domains=() d k
  server="$(p server)"
  plugin="$(p plugin)"
  keylength="$(p keylength)"
  provider="$(p provider)"
  desc="$(p dsm_desc)"
  force="$(p force)"
  valid_https_url "$server" || fail invalid_server
  valid_plugin "$plugin" || fail invalid_plugin
  valid_keylength "$keylength" || fail invalid_keylength
  [[ "$provider" =~ ^[a-z0-9_]{0,32}$ ]] || fail invalid_provider
  single_line "$desc" && [[ "$desc" != *\\* ]] && [ "${#desc}" -le 120 ] || fail invalid_desc
  while IFS= read -r d; do
    d="${d//[[:space:]]/}"
    [ -n "$d" ] || continue
    valid_domain "$d" || fail invalid_domain
    domains+=("$d")
  done <<<"$(p domains)"
  [ "${#domains[@]}" -gt 0 ] || fail invalid_domain
  [ "${#domains[@]}" -le 50 ] || fail invalid_domain
  # No description given: name the DSM certificate after the domain. An empty
  # description is deliberate and means the DSM default certificate.
  [ -n "${P[dsm_desc]+set}" ] || desc="${domains[0]}"
  # Export the DNS plugin credentials declared by that plugin.
  for k in "${!P[@]}"; do
    case "$k" in
      env_*)
        local var="${k#env_}" val="${P[$k]}"
        [ -n "$val" ] || continue
        dns_key_allowed "$plugin" "$var" || fail invalid_dns_option
        single_line "$val" || fail invalid_dns_option
        export "$var=$val"
        ;;
    esac
  done
  [ -n "$(p otp)" ] && export AACME_DSM_OTP="$(p otp)"
  local id
  id="$(job_spawn issue "${domains[0]}" -- "$server" "$plugin" "$keylength" "$(b64enc "$desc")" \
    "$([ "$force" = 1 ] && echo 1 || echo 0)" "$provider" "${domains[@]}")"
  respond "{\"ok\":true,\"job\":$(json_str "$id")}"
}

act_register() {
  local server email id
  server="$(p server)"
  email="$(p email)"
  valid_https_url "$server" || fail invalid_server
  [ -z "$email" ] || [[ "$email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || fail invalid_email
  if [ -n "$(p eab_kid)" ]; then
    single_line "$(p eab_kid)" && single_line "$(p eab_hmac)" || fail invalid_eab
    [ -n "$(p eab_hmac)" ] || fail invalid_eab
    export AACME_EAB_KID="$(p eab_kid)" AACME_EAB_HMAC="$(p eab_hmac)"
  fi
  id="$(job_spawn register "$server" -- "$server" "$email")"
  respond "{\"ok\":true,\"job\":$(json_str "$id")}"
}

act_cert_job() {
  local type="$1" id
  valid_cert_id "$(p id)" && [ -d "${ACME_CFG}/$(p id)" ] || fail cert_not_found
  [ -n "$(p otp)" ] && export AACME_DSM_OTP="$(p otp)"
  id="$(job_spawn "$type" "$(p id)" -- "$(p id)")"
  respond "{\"ok\":true,\"job\":$(json_str "$id")}"
}

act_expert() {
  local args=() a id
  while IFS= read -r a; do
    args+=("$a")
  done <<<"$(p args)"
  [ "${#args[@]}" -gt 0 ] && [ -n "${args[0]}" ] || fail invalid_args
  for a in "${args[@]}"; do
    case "$a" in
      --upgrade | --install* | --uninstall* | --home | --config-home | --cert-home | --auto-upgrade | --upgrade=*)
        fail expert_option_blocked
        ;;
    esac
  done
  id="$(job_spawn expert "acme.sh ${args[0]}" -- "${args[@]}")"
  respond "{\"ok\":true,\"job\":$(json_str "$id")}"
}

act_service_log() {
  respond "{\"ok\":true,\"log\":$(json_file_str "${AACME_LOGS}/service.log" 50000)}"
}

# --- Main -------------------------------------------------------------------

[ "${REQUEST_METHOD:-}" = "POST" ] || deny method_not_allowed
[ "${HTTP_X_AACME:-}" = "1" ] || deny csrf
USER_NAME="$(auth_user)"
[ -n "$USER_NAME" ] || deny not_logged_in
is_admin "$USER_NAME" || deny not_admin
aacme_init_dirs
parse_body

case "$(p action)" in
  status) respond "$(cmd_status)" ;;
  certs) respond "$(cmd_certs)" ;;
  accounts) respond "$(cmd_accounts)" ;;
  jobs) respond "$(cmd_jobs)" ;;
  job) respond "$(cmd_job_status "$(p id)")" ;;
  settings_set) respond "$(cmd_set "$(p key)" "$(p value)")" ;;
  dsm_check) respond "$(cmd_dsm_check "$(p user)" "$(p pass)" "$(p otp)")" ;;
  dsm_create_service) respond "$(cmd_dsm_create_service "$(p user)" "$(p pass)" "$(p otp)")" ;;
  dsm_forget) respond "$(cmd_dsm_forget)" ;;
  dsm_create_task) respond "$(cmd_dsm_create_task "$(p user)" "$(p pass)" "$(p otp)")" ;;
  dsm_task_remove) respond "$(cmd_dsm_task_remove)" ;;
  activity) respond "$(cmd_activity)" ;;
  ionos_zones)
    IONOS_PREFIX="$(p prefix)" IONOS_SECRET="$(p secret)"
    respond "$(cmd_ionos_zones)"
    ;;
  dns_saved)
    IFS=',' read -r -a keys <<<"$(p keys)"
    respond "$(cmd_dns_saved "${keys[@]}")"
    ;;
  register) act_register ;;
  issue) act_issue ;;
  renew) act_cert_job renew ;;
  deploy) act_cert_job deploy ;;
  remove)
    valid_cert_id "$(p id)" || fail cert_not_found
    respond "$(cmd_remove "$(p id)")"
    ;;
  set_target)
    valid_cert_id "$(p id)" && [ -d "${ACME_CFG}/$(p id)" ] || fail cert_not_found
    desc="$(p dsm_desc)"
    single_line "$desc" && [[ "$desc" != *\\* ]] && [ "${#desc}" -le 120 ] || fail invalid_desc
    respond "$(cmd_set_target "$(p id)" "$desc")"
    ;;
  expert) act_expert ;;
  acme_check) respond "$(cmd_acme_check)" ;;
  acme_update)
    acme_updates_allowed || fail acme_update_disabled
    tag="$(p tag)"
    [ -z "$tag" ] || valid_release_tag "$tag" || fail invalid_tag
    respond "{\"ok\":true,\"job\":$(json_str "$(job_spawn acme_update "${tag:-latest}" -- $tag)")}"
    ;;
  acme_revert) respond "$(cmd_acme_revert)" ;;
  service_log) act_service_log ;;
  *) fail unknown_action ;;
esac

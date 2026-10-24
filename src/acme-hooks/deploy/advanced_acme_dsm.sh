#!/usr/bin/env sh
# shellcheck disable=SC2034

# Advanced ACME deploy hook for Synology DSM.
#
# Thin wrapper around acme.sh's own synology_dsm hook that
#  - takes the DSM account from the package's protected secrets file instead of
#    storing it a second time in every domain config,
#  - detects how DSM is reachable on this NAS (HTTP or HTTPS on localhost),
#  - picks the DSM certificate description chosen in the GUI,
#  - records the deploy result for the GUI and remembers new 2FA device tokens.
#
# Without a DSM account the certificate is handed to the DSM task "Advanced
# ACME" instead (see lib/dsmtask.sh), which installs it as root.
#
# Usage: acme.sh --deploy -d example.com --deploy-hook advanced_acme_dsm

advanced_acme_dsm_deploy() {
  _aad_domain="$1"
  _aad_var="$(dirname "$LE_CONFIG_HOME")"
  _aad_secrets="$_aad_var/secrets/dsm.conf"
  _aad_meta="$_aad_var/meta/$(printf '%s' "$_aad_domain" | sed 's/^\*/_wildcard_/').conf"
  _aad_settings="$_aad_var/settings.conf"

  if [ ! -s "$2" ] || [ ! -s "$3" ]; then
    _err "Certificate or key file missing for $_aad_domain, nothing to deploy."
    _aad_status "fail" "cert_missing"
    return 1
  fi

  if [ -f "$_aad_var/dsm-task/task.conf" ]; then
    _aad_task_deploy "$@"
    return $?
  fi

  if [ ! -f "$_aad_secrets" ]; then
    _err "No DSM account configured. Open Advanced ACME > Settings > DSM account."
    _aad_status "fail" "dsm_no_credentials"
    return 1
  fi

  SYNO_USERNAME="$(_aad_kv "$_aad_secrets" user)"
  SYNO_PASSWORD="$(_aad_kv "$_aad_secrets" pass | base64 -d 2>/dev/null)"
  SYNO_DEVICE_ID="$(_aad_kv "$_aad_secrets" device_id)"
  SYNO_DEVICE_NAME="$(_aad_kv "$_aad_settings" dsm_device_name)"
  [ -n "$SYNO_DEVICE_NAME" ] || SYNO_DEVICE_NAME="AdvancedACME"
  # OTP is only passed in when the GUI asked the user for a fresh code.
  SYNO_OTP_CODE="${AACME_DSM_OTP:-}"
  [ -n "$SYNO_OTP_CODE" ] && SYNO_DEVICE_ID=""
  SYNO_USE_TEMP_ADMIN=""
  export SYNO_USERNAME SYNO_PASSWORD SYNO_DEVICE_ID SYNO_DEVICE_NAME SYNO_OTP_CODE

  # Certificate description in DSM (empty = DSM default certificate).
  if [ -f "$_aad_meta" ]; then
    SYNO_CERTIFICATE="$(_aad_kv "$_aad_meta" dsm_desc_b64 | base64 -d 2>/dev/null)"
  else
    SYNO_CERTIFICATE="$_aad_domain"
  fi
  SYNO_CREATE=1
  export SYNO_CERTIFICATE SYNO_CREATE

  _aad_detect
  export SYNO_SCHEME SYNO_HOSTNAME SYNO_PORT
  # Only the local DSM connection skips TLS verification: the NAS certificate
  # cannot match "localhost". This runs in a subshell of acme.sh's _deploy, so
  # ACME server requests are not affected.
  if [ "$SYNO_SCHEME" = "https" ] && [ "$SYNO_HOSTNAME" = "localhost" ]; then
    HTTPS_INSECURE=1
  fi

  # The synology_dsm hook falls back to values saved in the domain config when
  # a variable is empty (e.g. "" for the DSM default certificate). Our settings
  # are the single source of truth, so drop those saved values first.
  _aad_forget SYNO_CERTIFICATE SYNO_DEVICE_ID SYNO_USERNAME SYNO_PASSWORD

  _aad_hook="$(dirname "$_deployApi")/synology_dsm.sh"
  if ! . "$_aad_hook"; then
    _err "Cannot load $_aad_hook"
    _aad_status "fail" "hook_missing"
    return 1
  fi

  if synology_dsm_deploy "$@"; then
    _aad_rc=0
  else
    _aad_rc=1
  fi

  # Keep the DSM account only in the secrets file, not in the domain config.
  _aad_forget SYNO_USERNAME SYNO_PASSWORD SYNO_DEVICE_ID

  if [ "$_aad_rc" = 0 ]; then
    if [ -n "$SYNO_DEVICE_ID" ] && [ "$SYNO_DEVICE_ID" != "$(_aad_kv "$_aad_secrets" device_id)" ]; then
      _aad_kvset "$_aad_secrets" device_id "$SYNO_DEVICE_ID"
    fi
    _aad_status "ok" ""
  else
    _aad_status "fail" "deploy_failed"
  fi
  return "$_aad_rc"
}

# _aad_task_deploy DOMAIN KEY CERT CA FULLCHAIN: queue the certificate for the
# DSM task and wait for its result. The task runs every minute.
_aad_task_deploy() {
  _aad_q="$_aad_var/dsm-task/queue"
  _aad_run="${AACME_TASK_RUN:-/run/advanced-acme}"
  _aad_name="$(basename "$(dirname "$2")")"
  _aad_nonce="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  if [ -f "$_aad_meta" ]; then
    _aad_desc_b64="$(_aad_kv "$_aad_meta" dsm_desc_b64)"
  else
    _aad_desc_b64="$(printf '%s' "$_aad_domain" | base64 | tr -d '\n')"
  fi
  mkdir -p "$_aad_q"
  _aad_req="$_aad_q/.${_aad_name}.$$"
  {
    printf 'nonce=%s\ndomain=%s\ndesc_b64=%s\n' "$_aad_nonce" "$_aad_domain" "$_aad_desc_b64"
    printf 'key_b64=%s\n' "$(base64 <"$2" | tr -d '\n')"
    printf 'cert_b64=%s\n' "$(base64 <"$3" | tr -d '\n')"
    printf 'chain_b64=%s\n' "$(base64 <"$4" | tr -d '\n')"
  } >"$_aad_req" && chmod 600 "$_aad_req" && mv -f "$_aad_req" "$_aad_q/${_aad_name}.req"
  _info "Handed over to the DSM task \"Advanced ACME\", waiting for it to install the certificate..."
  _aad_i=0
  while [ "$_aad_i" -lt "${AACME_TASK_WAIT:-150}" ]; do
    if [ "$(_aad_kv "$_aad_run/${_aad_name}.result" nonce)" = "$_aad_nonce" ]; then
      if [ "$(_aad_kv "$_aad_run/${_aad_name}.result" status)" = ok ]; then
        _info "The DSM task installed the certificate."
        _aad_status "ok" ""
        return 0
      fi
      _err "The DSM task could not install the certificate (error $(_aad_kv "$_aad_run/${_aad_name}.result" code))."
      _aad_status "fail" "task_$(_aad_kv "$_aad_run/${_aad_name}.result" code)"
      return 1
    fi
    sleep 2
    _aad_i=$((_aad_i + 2))
  done
  _info "The DSM task has not run yet. It will install the certificate at its next run."
  echo "@@INFO deploy_queued"
  _aad_status "queued" ""
  return 0
}

# Remove saved deploy values from the domain config. acme.sh sourced that file
# before calling the hook and _readdomainconf falls back to the shell variable
# of the same name, so the SAVED_* variables are unset as well.
_aad_forget() {
  for _aad_key in "$@"; do
    _cleardeployconf "$_aad_key"
    unset "SAVED_$_aad_key"
  done
}

_aad_kv() {
  [ -f "$1" ] || return 0
  sed -n "s/^$2=//p" "$1" | head -n1
}

_aad_kvset() {
  _aad_tmp="$1.tmp.$$"
  { grep -v "^$2=" "$1" 2>/dev/null; printf '%s=%s\n' "$2" "$3"; } >"$_aad_tmp" && mv -f "$_aad_tmp" "$1"
  chmod 600 "$1" 2>/dev/null
}

_aad_status() {
  mkdir -p "$(dirname "$_aad_meta")"
  [ -f "$_aad_meta" ] || : >"$_aad_meta"
  _aad_kvset "$_aad_meta" deploy_status "$1"
  _aad_kvset "$_aad_meta" deploy_error "$2"
  _aad_kvset "$_aad_meta" deploy_time "$(date +%s)"
}

_aad_detect() {
  SYNO_HOSTNAME="$(_aad_kv "$_aad_settings" dsm_host)"
  [ -n "$SYNO_HOSTNAME" ] || SYNO_HOSTNAME=localhost
  SYNO_SCHEME="$(_aad_kv "$_aad_settings" dsm_scheme)"
  SYNO_PORT="$(_aad_kv "$_aad_settings" dsm_port)"
  [ -n "$SYNO_SCHEME" ] && [ -n "$SYNO_PORT" ] && return 0
  _aad_info="${AACME_SYNOINFO:-/etc/synoinfo.conf}"
  _aad_http="$(sed -n 's/^admin_port="\{0,1\}\([0-9]*\)"\{0,1\}$/\1/p' "$_aad_info" 2>/dev/null | head -n1)"
  _aad_https="$(sed -n 's/^secure_admin_port="\{0,1\}\([0-9]*\)"\{0,1\}$/\1/p' "$_aad_info" 2>/dev/null | head -n1)"
  [ -n "$_aad_http" ] || _aad_http=5000
  [ -n "$_aad_https" ] || _aad_https=5001
  if curl -s --max-time 10 "http://$SYNO_HOSTNAME:$_aad_http/webapi/query.cgi?api=SYNO.API.Info&version=1&method=query&query=SYNO.API.Auth" 2>/dev/null | grep -q '"SYNO.API.Auth"'; then
    SYNO_SCHEME=http
    SYNO_PORT="$_aad_http"
  else
    SYNO_SCHEME=https
    SYNO_PORT="$_aad_https"
  fi
}

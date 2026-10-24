#!/bin/bash
# Shared helpers for Advanced ACME. Sourced by the CLI, the CGI and the service.
# Requires bash >= 4.4 (DSM 7 ships 4.4).

AACME_PKG="${AACME_PKG:-AdvancedACME}"
AACME_TARGET="${AACME_TARGET:-/var/packages/${AACME_PKG}/target}"
AACME_VAR="${AACME_VAR:-/var/packages/${AACME_PKG}/var}"

export AACME_TARGET AACME_VAR

# acme.sh shipped with the package, and an optional newer copy installed by
# the acme.sh update function (see acmeupdate.sh). ACME_HOME is chosen at the
# end of this file.
ACME_BUNDLED="${AACME_TARGET}/acme.sh"
ACME_UPDATED="${AACME_VAR}/acme-sh"
ACME_HOME="$ACME_BUNDLED"
ACME_CFG="${AACME_VAR}/acme"
AACME_SECRETS="${AACME_VAR}/secrets"
AACME_META="${AACME_VAR}/meta"
AACME_JOBS="${AACME_VAR}/jobs"
AACME_LOGS="${AACME_VAR}/logs"
AACME_SETTINGS="${AACME_VAR}/settings.conf"
AACME_LOCK="${AACME_VAR}/lock"
AACME_ACTIVITY="${AACME_LOGS}/activity.log"

# Synology tools live outside the default PATH of package processes.
export PATH="/bin:/sbin:/usr/bin:/usr/sbin:/usr/syno/bin:/usr/syno/sbin:/usr/local/bin:${PATH}"
export HOME="${AACME_VAR}"
umask 077

aacme_init_dirs() {
  mkdir -p "$ACME_CFG" "$AACME_SECRETS" "$AACME_META" "$AACME_JOBS" "$AACME_LOGS" 2>/dev/null
  chmod 700 "$AACME_VAR" "$AACME_SECRETS" 2>/dev/null
  return 0
}

# activity_log EVENT [KEY VALUE]...: one JSON line for every step the user
# should be able to retrace later (DSM account, DSM task). The GUI translates
# the event keys.
activity_log() {
  local ev="$1" args=""
  shift
  while [ $# -ge 2 ]; do
    args+="${args:+,}$(json_str "$1"):$(json_str "$2")"
    shift 2
  done
  mkdir -p "$AACME_LOGS"
  printf '{"t":%s,"e":%s,"a":{%s}}\n' "$(date +%s)" "$(json_str "$ev")" "$args" >>"$AACME_ACTIVITY"
  if [ "$(wc -l <"$AACME_ACTIVITY")" -gt 250 ]; then
    tail -n 200 "$AACME_ACTIVITY" >"${AACME_ACTIVITY}.tmp" && mv -f "${AACME_ACTIVITY}.tmp" "$AACME_ACTIVITY"
  fi
}

cmd_activity() {
  printf '{"ok":true,"events":['
  tail -n 100 "$AACME_ACTIVITY" 2>/dev/null | grep '^{' | sed '$!s/$/,/' | tr -d '\n'
  printf ']}'
}

aacme_version() {
  local v
  v="$(sed -n 's/^version="\(.*\)"$/\1/p' "/var/packages/${AACME_PKG}/INFO" 2>/dev/null)"
  [ -n "$v" ] || v="$(cat "${AACME_TARGET}/VERSION" 2>/dev/null)"
  printf '%s' "${v:-dev}"
}

# --- JSON output -------------------------------------------------------------

# Escape a string for use inside a JSON string literal.
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  # Drop all remaining control characters.
  s="$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037\177')"
  printf '%s' "$s"
}

# json_str VALUE -> "VALUE"
json_str() { printf '"%s"' "$(json_escape "$1")"; }

# json_bool VALUE -> true when VALUE is 1/true/yes
json_bool() {
  case "$1" in 1 | true | yes) printf 'true' ;; *) printf 'false' ;; esac
}

# json_num VALUE -> number or null
json_num() {
  if [[ "$1" =~ ^-?[0-9]+$ ]]; then printf '%s' "$1"; else printf 'null'; fi
}

# json_file_str FILE [MAXBYTES] -> file content (tail) as JSON string
json_file_str() {
  local f="$1" max="${2:-200000}"
  if [ -f "$f" ]; then
    json_str "$(tail -c "$max" "$f" | strip_ansi)"
  else
    printf '""'
  fi
}

strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }

# --- Simple key=value stores (never sourced, so values cannot execute) -----

# kv_get FILE KEY [DEFAULT]
kv_get() {
  local f="$1" key="$2" def="${3:-}" k v
  if [ -f "$f" ]; then
    while IFS='=' read -r k v || [ -n "$k" ]; do
      if [ "$k" = "$key" ]; then
        printf '%s' "$v"
        return 0
      fi
    done <"$f"
  fi
  printf '%s' "$def"
}

# kv_set FILE KEY VALUE  (VALUE must be single-line)
kv_set() {
  local f="$1" key="$2" val="$3" tmp k v
  val="${val//$'\n'/}"
  val="${val//$'\r'/}"
  tmp="${f}.tmp.$$"
  {
    if [ -f "$f" ]; then
      while IFS='=' read -r k v || [ -n "$k" ]; do
        if [ -n "$k" ] && [ "$k" != "$key" ]; then
          printf '%s=%s\n' "$k" "$v"
        fi
      done <"$f"
    fi
    printf '%s=%s\n' "$key" "$val"
  } >"$tmp" && mv -f "$tmp" "$f"
  chmod 600 "$f" 2>/dev/null
}

kv_del() {
  local f="$1" key="$2" tmp k v
  [ -f "$f" ] || return 0
  tmp="${f}.tmp.$$"
  while IFS='=' read -r k v || [ -n "$k" ]; do
    if [ -n "$k" ] && [ "$k" != "$key" ]; then
      printf '%s=%s\n' "$k" "$v"
    fi
  done <"$f" >"$tmp"
  mv -f "$tmp" "$f"
  chmod 600 "$f" 2>/dev/null
  return 0
}

b64enc() { printf '%s' "$1" | base64 | tr -d '\n'; }
b64dec() { printf '%s' "$1" | base64 -d 2>/dev/null; }

# --- Settings ----------------------------------------------------------------

setting() {
  local key="$1" def
  case "$key" in
    renew_before_days) def=30 ;;
    notify) def=1 ;;
    dsm_device_name) def="AdvancedACME" ;;
    acme_auto_update) def=0 ;;
    *) def="" ;;
  esac
  kv_get "$AACME_SETTINGS" "$key" "$def"
}

# --- Validation --------------------------------------------------------------

valid_domain() {
  # Hostname or wildcard (*.example.com); IDNs must be given in punycode.
  [[ "$1" =~ ^(\*\.)?([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z0-9-]{2,63}$ ]]
}

valid_cert_id() {
  # acme.sh directory name: <domain> or <domain>_ecc
  [[ "$1" =~ ^(\*\.)?[A-Za-z0-9.-]+(_ecc)?$ ]] && [[ "$1" != *..* ]]
}

valid_https_url() {
  [[ "$1" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~%/+-]*)?$ ]]
}

valid_plugin() {
  [[ "$1" =~ ^dns_[A-Za-z0-9_]+$ ]] && [ -f "${ACME_HOME}/dnsapi/$1.sh" ]
}

valid_keylength() {
  case "$1" in ec-256 | ec-384 | 2048 | 3072 | 4096) return 0 ;; *) return 1 ;; esac
}

# --- acme.sh -----------------------------------------------------------------

# Run the bundled acme.sh with the package's home and config directories.
acme() {
  "${ACME_HOME}/acme.sh" --home "$ACME_HOME" --config-home "$ACME_CFG" "$@" </dev/null
}

# acme_sh_version [HOME]: version of the acme.sh in HOME (default: active one).
acme_sh_version() {
  sed -n 's/^VER=\(.*\)$/\1/p' "${1:-$ACME_HOME}/acme.sh" 2>/dev/null | head -n1
}

# version_gt A B: true when dotted version A is newer than B (numeric parts).
version_gt() {
  local IFS=. i a b
  local -a va=($1) vb=($2)
  for ((i = 0; i < ${#va[@]} || i < ${#vb[@]}; i++)); do
    a="${va[i]:-0}"
    b="${vb[i]:-0}"
    a="${a//[!0-9]/}"
    b="${b//[!0-9]/}"
    [ "${a:-0}" -gt "${b:-0}" ] && return 0
    [ "${a:-0}" -lt "${b:-0}" ] && return 1
  done
  return 1
}

# The updated acme.sh is used only while it is newer than the bundled one, so a
# package update that ships a newer acme.sh takes precedence automatically.
acme_updated_active() {
  [ -f "${ACME_UPDATED}/acme.sh" ] &&
    version_gt "$(acme_sh_version "$ACME_UPDATED")" "$(acme_sh_version "$ACME_BUNDLED")"
}

# Read a value from an acme.sh domain/account conf (format KEY='value').
acme_conf_get() {
  local f="$1" key="$2" line
  [ -f "$f" ] || return 0
  line="$(grep -m1 "^${key}=" "$f" 2>/dev/null)" || return 0
  line="${line#*=}"
  line="${line#\'}"
  line="${line%\'}"
  printf '%s' "$line"
}

# --- Locking -----------------------------------------------------------------

# lock_acquire TIMEOUT_SECONDS: mkdir-based lock, stale locks are taken over.
lock_acquire() {
  local timeout="${1:-1800}" waited=0 pid
  while ! mkdir "$AACME_LOCK" 2>/dev/null; do
    pid="$(cat "${AACME_LOCK}/pid" 2>/dev/null)"
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
      rm -rf "$AACME_LOCK"
      continue
    fi
    if [ "$waited" -ge "$timeout" ]; then
      return 1
    fi
    sleep 2
    waited=$((waited + 2))
  done
  echo "$$" >"${AACME_LOCK}/pid"
  return 0
}

lock_release() {
  [ "$(cat "${AACME_LOCK}/pid" 2>/dev/null)" = "$$" ] && rm -rf "$AACME_LOCK"
  return 0
}

lock_busy() {
  local pid
  [ -d "$AACME_LOCK" ] || return 1
  pid="$(cat "${AACME_LOCK}/pid" 2>/dev/null)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# --- DSM notifications (best effort) ----------------------------------------

notify_admins() {
  local key="$1"
  [ "$(setting notify)" = "1" ] || return 0
  command -v synodsmnotify >/dev/null 2>&1 || return 0
  synodsmnotify -c "SYNO.SDS.${AACME_PKG}.Application" @administrators \
    "${AACME_PKG}:app:title" "${AACME_PKG}:notify:${key}" >/dev/null 2>&1 || true
}

log_line() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"${AACME_LOGS}/service.log"
}

rotate_log() {
  local f="$1" max="${2:-1048576}" size
  [ -f "$f" ] || return 0
  size="$(wc -c <"$f" 2>/dev/null || echo 0)"
  if [ "$size" -gt "$max" ]; then
    mv -f "$f" "${f}.1"
  fi
}

# acme_select_home: (re)choose the acme.sh to run, e.g. after an update.
acme_select_home() {
  if acme_updated_active; then
    ACME_HOME="$ACME_UPDATED"
  else
    ACME_HOME="$ACME_BUNDLED"
  fi
}
acme_select_home

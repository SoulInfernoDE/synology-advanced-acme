#!/bin/bash
# DNS provider helpers.

IONOS_DNS_API="${AACME_IONOS_API:-https://api.hosting.ionos.com/dns}"

# cmd_ionos_zones: list the zones reachable with IONOS_PREFIX / IONOS_SECRET
# (taken from the environment, or from acme.sh's account.conf when empty).
cmd_ionos_zones() {
  local prefix="${IONOS_PREFIX:-}" secret="${IONOS_SECRET:-}" resp code body names
  local acc="${ACME_CFG}/account.conf"
  [ -n "$prefix" ] || prefix="$(acme_conf_get "$acc" SAVED_IONOS_PREFIX)"
  [ -n "$secret" ] || secret="$(acme_conf_get "$acc" SAVED_IONOS_SECRET)"
  if [ -z "$prefix" ] || [ -z "$secret" ]; then
    printf '{"ok":false,"error":"ionos_no_key"}'
    return 0
  fi
  resp="$(curl -s --max-time 20 -w '\n%{http_code}' -H "X-API-Key: ${prefix}.${secret}" \
    -H "Accept: application/json" "${IONOS_DNS_API}/v1/zones" 2>/dev/null)"
  code="${resp##*$'\n'}"
  body="${resp%$'\n'*}"
  case "$code" in
    200) ;;
    401 | 403)
      printf '{"ok":false,"error":"ionos_key_rejected"}'
      return 0
      ;;
    000 | "")
      printf '{"ok":false,"error":"ionos_unreachable"}'
      return 0
      ;;
    *)
      printf '{"ok":false,"error":"ionos_http_error","detail":%s}' "$(json_str "$code")"
      return 0
      ;;
  esac
  # The key works: keep it for renewals. acme.sh's IONOS plugin would only
  # save it when it actually creates a DNS entry, which it skips while IONOS
  # still remembers an earlier validation.
  if [ -n "${IONOS_PREFIX:-}" ]; then
    acme_conf_set "$acc" SAVED_IONOS_PREFIX "$prefix"
    acme_conf_set "$acc" SAVED_IONOS_SECRET "$secret"
  fi
  names="$(printf '%s' "$body" | grep -o '"name" *: *"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/' | sort -u)"
  printf '{"ok":true,"saved":%s,"zones":[' "$(json_bool "$([ -z "${IONOS_PREFIX:-}" ] && echo 1)")"
  local first=1 n
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    [ "$first" = 1 ] || printf ','
    first=0
    printf '%s' "$(json_str "$n")"
  done <<<"$names"
  printf ']}'
}

# Is a credential of a DNS plugin already stored by acme.sh? Prints a JSON
# object {"KEY":true|false,...} for the given keys.
cmd_dns_saved() {
  local acc="${ACME_CFG}/account.conf" first=1 k
  printf '{"ok":true,"saved":{'
  for k in "$@"; do
    [[ "$k" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    [ "$first" = 1 ] || printf ','
    first=0
    printf '%s:%s' "$(json_str "$k")" "$(json_bool "$(grep -qE "^(SAVED_)?${k}=" "$acc" 2>/dev/null && echo 1)")"
  done
  printf '}}'
}

# dns_save_env PLUGIN: store the plugin's credentials from the environment in
# acme.sh's account.conf (after a successful issue; see cmd_ionos_zones).
dns_save_env() {
  local k
  while read -r _ k; do
    [ -n "${!k:-}" ] && acme_conf_set "${ACME_CFG}/account.conf" "SAVED_$k" "${!k}"
  done < <(grep "^$1 " "${AACME_TARGET}/share/dnsapi.keys" 2>/dev/null)
  return 0
}

# dns_key_allowed PLUGIN KEY: only variables declared by the plugin may be set.
dns_key_allowed() {
  grep -qx "$1 $2" "${AACME_TARGET}/share/dnsapi.keys" 2>/dev/null
}

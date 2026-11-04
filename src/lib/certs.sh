#!/bin/bash
# Certificate inventory read from acme.sh's config home.

meta_file() {
  local name="$1"
  name="${name/#\*/_wildcard_}"
  printf '%s/%s.conf' "$AACME_META" "$name"
}

# date_to_epoch "Mar 10 12:00:00 2027 GMT" -> seconds or empty
date_to_epoch() {
  date -u -d "$1" +%s 2>/dev/null || true
}

cert_json() {
  local dir="$1" id domain conf cer alt server plugin keylen created next hook deployed
  local not_after_str not_after issuer meta desc alt_json first d
  id="$(basename "$dir")"
  domain="${id%_ecc}"
  conf="${dir}/${domain}.conf"
  [ -f "$conf" ] || return 1
  cer="${dir}/${domain}.cer"
  alt="$(acme_conf_get "$conf" Le_Alt)"
  server="$(acme_conf_get "$conf" Le_API)"
  plugin="$(acme_conf_get "$conf" Le_Webroot)"
  keylen="$(acme_conf_get "$conf" Le_Keylength)"
  created="$(acme_conf_get "$conf" Le_CertCreateTime)"
  next="$(acme_conf_get "$conf" Le_NextRenewTime)"
  hook="$(acme_conf_get "$conf" Le_DeployHook)"
  deployed="$(acme_conf_get "$conf" Le_DeploySuccessTime)"
  not_after_str=""
  issuer=""
  if [ -s "$cer" ]; then
    not_after_str="$(openssl x509 -noout -enddate -in "$cer" 2>/dev/null | sed 's/^notAfter=//')"
    issuer="$(openssl x509 -noout -issuer -in "$cer" 2>/dev/null | sed 's/^issuer= *//')"
  fi
  not_after=""
  [ -n "$not_after_str" ] && not_after="$(date_to_epoch "$not_after_str")"
  meta="$(meta_file "$domain")"
  desc="$(b64dec "$(kv_get "$meta" dsm_desc_b64)")"

  alt_json="["
  first=1
  if [ -n "$alt" ] && [ "$alt" != "no" ]; then
    for d in ${alt//,/ }; do
      [ "$first" = 1 ] || alt_json+=","
      first=0
      alt_json+="$(json_str "$d")"
    done
  fi
  alt_json+="]"

  printf '{"id":%s,"domain":%s,"alt":%s,"server":%s,"plugin":%s,"keylength":%s,"created":%s,"next_renew":%s,"not_after":%s,"not_after_str":%s,"issuer":%s,"deploy_hook":%s,"deployed":%s,"deploy_status":%s,"deploy_error":%s,"deploy_time":%s,"dsm_desc":%s,"has_meta":%s,"provider":%s}' \
    "$(json_str "$id")" "$(json_str "$domain")" "$alt_json" "$(json_str "$server")" "$(json_str "$plugin")" \
    "$(json_str "$keylen")" "$(json_num "$created")" "$(json_num "$next")" "$(json_num "$not_after")" \
    "$(json_str "$not_after_str")" "$(json_str "$issuer")" "$(json_str "$hook")" "$(json_num "$deployed")" \
    "$(json_str "$(kv_get "$meta" deploy_status)")" "$(json_str "$(kv_get "$meta" deploy_error)")" \
    "$(json_num "$(kv_get "$meta" deploy_time)")" "$(json_str "$desc")" "$(json_bool "$([ -f "$meta" ] && echo 1)")" \
    "$(json_str "$(kv_get "$meta" provider)")"
}

# log_due_certs SINCE: certificates obtained since SINCE that are already due
# for renewal. Some CAs hand out a certificate that expires soon instead of a
# new one (IONOS returns the existing certificate for a while). Prints
# "@@INFO issued_due <not_after>" for the job log and records it in the
# history; acme.sh keeps trying at every renewal check.
log_due_certs() {
  local since="$1" now dir id domain conf created next na
  now="$(date +%s)"
  for dir in "$ACME_CFG"/*/; do
    id="$(basename "$dir")"
    domain="${id%_ecc}"
    conf="${dir}${domain}.conf"
    [ -f "$conf" ] || continue
    created="$(acme_conf_get "$conf" Le_CertCreateTime)"
    next="$(acme_conf_get "$conf" Le_NextRenewTime)"
    [[ "$created" =~ ^[0-9]+$ ]] && [[ "$next" =~ ^[0-9]+$ ]] || continue
    [ "$created" -ge "$since" ] && [ "$next" -le "$now" ] || continue
    na="$(date_to_epoch "$(openssl x509 -noout -enddate -in "${dir}${domain}.cer" 2>/dev/null | sed 's/^notAfter=//')")"
    [[ "$na" =~ ^[0-9]+$ ]] || na=0
    echo "@@INFO issued_due ${na}"
    activity_log cert_delivered_due cert "$domain" until "$(date -d "@${na}" +%Y-%m-%d 2>/dev/null)"
  done
  return 0
}

cmd_certs() {
  local first=1 dir out
  task_collect
  printf '{"ok":true,"certs":['
  for dir in "$ACME_CFG"/*/; do
    dir="${dir%/}"
    [ -d "$dir" ] || continue
    case "$(basename "$dir")" in ca | deploy | dnsapi | notify) continue ;; esac
    out="$(cert_json "$dir")" || continue
    [ "$first" = 1 ] || printf ','
    first=0
    printf '%s' "$out"
  done
  printf ']}'
}

# cmd_set_target CERT_ID DESC: change the DSM certificate description used for deploys.
cmd_set_target() {
  local id="$1" desc="$2" meta
  meta="$(meta_file "${id%_ecc}")"
  touch "$meta"
  kv_set "$meta" dsm_desc_b64 "$(b64enc "$desc")"
  printf '{"ok":true}'
}

cmd_remove() {
  local id="$1" domain ecc=() dir out
  domain="${id%_ecc}"
  [ "$domain" != "$id" ] && ecc=(--ecc)
  dir="${ACME_CFG}/${id}"
  if [ ! -d "$dir" ]; then
    printf '{"ok":false,"error":"cert_not_found"}'
    return 0
  fi
  if ! lock_acquire 30; then
    printf '{"ok":false,"error":"busy"}'
    return 0
  fi
  out="$(acme --remove -d "$domain" "${ecc[@]}" 2>&1)"
  rm -rf "$dir"
  rm -f "$(meta_file "$domain")"
  lock_release
  printf '{"ok":true,"log":%s}' "$(json_str "$(printf '%s' "$out" | strip_ansi)")"
}

# Accounts registered per ACME server (ca/<host>/<path>/account.json).
cmd_accounts() {
  local first=1 f rel
  printf '{"ok":true,"accounts":['
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel="${f#"${ACME_CFG}/ca/"}"
    rel="${rel%/account.json}"
    [ "$first" = 1 ] || printf ','
    first=0
    printf '%s' "$(json_str "https://${rel}")"
  done < <(find "${ACME_CFG}/ca" -name account.json 2>/dev/null | sort)
  printf ']}'
}

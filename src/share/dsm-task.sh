#!/bin/sh
# Advanced ACME: DSM task "@NAME@" (script version @SCRIPT_VERSION@).
#
# Runs as root through the DSM Task Scheduler and installs the certificates
# that Advanced ACME has renewed, the way DSM installs its own Let's Encrypt
# certificates: locally with synowebapi, without a DSM account or 2-step
# verification. Created by Advanced ACME with the consent of an administrator.
#
# Security: this script is stored in the task itself (root-owned). It never
# runs files of the package, it only reads requests from the package folder,
# checks them and writes its results to @RUN@, which belongs to root. It
# deletes itself when Advanced ACME is uninstalled or asks for it.

Q='@QUEUE@'
R='@RUN@'
W='@SYNOWEBAPI@'
PKG='@PKGDIR@'
NAME='@NAME@'
VERSION='@SCRIPT_VERSION@'
PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/syno/bin:/usr/syno/sbin
export PATH
umask 022

api() { "$W" --exec "$@" 2>/dev/null | sed -n '/^{/,$p'; }

# put FILE TEXT: replace a result file atomically.
put() {
  _t="$(mktemp "$R/.tmp.XXXXXX")" || return 1
  printf '%s\n' "$2" >"$_t" && chmod 644 "$_t" && mv -f "$_t" "$R/$1"
}

self_delete() {
  _id="$(api api=SYNO.Core.TaskScheduler method=list version=3 |
    jq -r --arg n "$NAME" '[.data.tasks[]? | select(.name == $n and .owner == "root")][0].id // empty')"
  case "$_id" in '' | *[!0-9]*) return 1 ;; esac
  api api=SYNO.Core.TaskScheduler method=delete version=2 "tasks=[{\"id\":$_id,\"real_owner\":\"root\"}]" >/dev/null
}

mkdir -p "$R" && chmod 755 "$R" || exit 1

# Advanced ACME was uninstalled, or the user removed the task in Advanced ACME.
# Confirm first: DSM stops a running task when it is deleted.
if [ ! -d "$PKG" ] || [ -e "$Q/remove" ]; then
  put removed "time=$(date +%s)"
  self_delete
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  put heartbeat "time=$(date +%s)
version=$VERSION
error=jq_missing"
  exit 1
fi

# Certificate list for the target choice in Advanced ACME (names only, no keys).
list_certs() {
  _c="$(api api=SYNO.Core.Certificate.CRT method=list version=1)"
  _j="$(printf '%s' "$_c" | jq -c '{certificates: [.data.certificates[]? | {desc, id, is_default, renewable,
    subject: {common_name: .subject.common_name}, valid_till, services: [.services[]? | {display_name}]}]}')" &&
    [ -n "$_j" ] && put certs.json "$_j"
}
if [ -z "$(find "$R/certs.json" -mmin -5 2>/dev/null)" ]; then
  list_certs
fi

for req in "$Q"/queue/*.req; do
  [ -f "$req" ] || continue
  name="${req##*/}"
  name="${name%.req}"
  case "$name" in '' | *[!A-Za-z0-9._-]*) continue ;; esac
  [ "$(stat -c %s "$req" 2>/dev/null || echo 999999)" -le 262144 ] || continue
  data="$(head -c 262144 "$req")"
  nonce="$(printf '%s\n' "$data" | sed -n 's/^nonce=//p' | head -n1)"
  case "$nonce" in '' | *[!A-Za-z0-9]*) continue ;; esac
  # Done already; Advanced ACME has not picked up the result yet.
  [ "$(sed -n 's/^nonce=//p' "$R/$name.result" 2>/dev/null)" = "$nonce" ] && continue

  status=fail
  code=""
  cid=""
  tmp="$(mktemp -d /tmp/aacme.XXXXXX)" || continue
  for f in key cert chain; do
    printf '%s\n' "$data" | sed -n "s/^${f}_b64=//p" | head -n1 | base64 -d >"$tmp/$f.pem" 2>/dev/null
  done
  desc="$(printf '%s\n' "$data" | sed -n 's/^desc_b64=//p' | head -n1 | base64 -d 2>/dev/null)"
  if ! openssl x509 -noout -in "$tmp/cert.pem" 2>/dev/null || ! openssl pkey -noout -in "$tmp/key.pem" 2>/dev/null; then
    code=invalid_cert
  elif [ "${#desc}" -gt 120 ] || [ "$(printf '%s' "$desc" | wc -l)" -gt 0 ] || printf '%s' "$desc" | grep -q '[[:cntrl:]]'; then
    code=invalid_desc
  else
    certs="$(api api=SYNO.Core.Certificate.CRT method=list version=1)"
    # Empty description: the DSM default certificate. Replacing keeps the
    # services that use it.
    if [ -z "$desc" ]; then
      cid="$(printf '%s' "$certs" | jq -r '[.data.certificates[]? | select(.is_default == true)][0].id // empty')"
    else
      cid="$(printf '%s' "$certs" | jq -r --arg d "$desc" '[.data.certificates[]? | select(.desc == $d)][0].id // empty')"
    fi
    case "$cid" in *[!A-Za-z0-9]*) cid="" ;; esac
    set -- api=SYNO.Core.Certificate method=import version=1 "key_tmp=\"$tmp/key.pem\"" \
      "cert_tmp=\"$tmp/cert.pem\"" "desc=$(jq -n --arg d "$desc" '$d')"
    openssl x509 -noout -in "$tmp/chain.pem" 2>/dev/null && set -- "$@" "inter_cert_tmp=\"$tmp/chain.pem\""
    [ -n "$cid" ] && set -- "$@" "id=\"$cid\""
    out="$(api "$@")"
    if [ "$(printf '%s' "$out" | jq -r '.success')" = true ]; then
      status=ok
      [ -n "$cid" ] || cid="$(printf '%s' "$out" | jq -r '.data.id // empty')"
    else
      code="$(printf '%s' "$out" | jq -r '.error.code // "unknown"')"
    fi
  fi
  rm -rf "$tmp"
  put "$name.result" "nonce=$nonce
status=$status
code=$code
id=$cid
time=$(date +%s)"
  [ "$status" = ok ] && list_certs
done

put heartbeat "time=$(date +%s)
version=$VERSION"
exit 0

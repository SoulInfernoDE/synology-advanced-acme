#!/bin/sh
# Advanced ACME: DSM task "@NAME@" (script version @SCRIPT_VERSION@).
#
# Runs as root through the DSM Task Scheduler and installs the certificates
# that Advanced ACME has renewed, the way DSM installs its own Let's Encrypt
# certificates: locally with synowebapi, without a DSM account or 2-step
# verification. Created by Advanced ACME with the consent of an administrator.
#
# DSM starts the task at boot (triggered task, event "boot-up") and it stays
# in the background. Every @INTERVAL@ seconds it looks for requests in the
# package folder. While there is nothing to do it does not touch the disks:
# the folder is read from the cache, and results go to @RUN@ in RAM. DSM writes
# the output of a task to a file on the volume, so the script prints nothing.
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
INTERVAL='@INTERVAL@'
# Seconds the package folder must stay missing before the task removes itself.
GRACE='@GRACE@'
PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/syno/bin:/usr/syno/sbin
export PATH
umask 022
exec </dev/null >/dev/null 2>&1

api() { "$W" --exec "$@" 2>/dev/null | sed -n '/^{/,$p'; }

# put FILE TEXT: replace a result file atomically.
put() {
  _t="$(mktemp "$R/.tmp.XXXXXX")" || return 1
  printf '%s\n' "$2" >"$_t" && chmod 644 "$_t" && mv -f "$_t" "$R/$1"
}

heartbeat() {
  put heartbeat "time=$(date +%s)
version=$VERSION
pid=$ME${1:+
error=$1}"
}

# DSM does not stop a running task when it is deleted, so the script ends
# itself afterwards.
self_delete() {
  api api=SYNO.Core.EventScheduler method=delete version=1 "task_name=\"$NAME\"" >/dev/null
}

# Certificate list for the target choice in Advanced ACME (names only, no
# keys): at start, after an installation and when Advanced ACME asks for it.
list_certs() {
  _c="$(api api=SYNO.Core.Certificate.CRT method=list version=1)"
  _j="$(printf '%s' "$_c" | jq -c '{certificates: [.data.certificates[]? | {desc, id, is_default, renewable,
    subject: {common_name: .subject.common_name}, valid_till, services: [.services[]? | {display_name}]}]}')" &&
    [ -n "$_j" ] && put certs.json "$_j"
  : >"$R/.listed"
}

# install_requests: import the certificates Advanced ACME has handed over.
install_requests() {
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
}

mkdir -p "$R" && chmod 755 "$R" || exit 1
ME=$$

if ! command -v jq >/dev/null 2>&1; then
  heartbeat jq_missing
  exit 1
fi

# A newer start (Advanced ACME set the task up again) takes over; an older
# instance sees it and ends.
: >"$R/.started.$ME"
put pid "$ME"
list_certs
heartbeat

gone=0
beat=0
while :; do
  owner=""
  read -r owner <"$R/pid" 2>/dev/null
  if [ "$owner" != "$ME" ]; then
    rm -f "$R/.started.$ME"
    exit 0
  fi

  # The user removed the task in Advanced ACME, or Advanced ACME was
  # uninstalled (the package folder stays missing; a package update replaces
  # it only for a moment).
  if [ -d "$PKG" ]; then
    gone=0
  else
    gone=$((gone + INTERVAL))
  fi
  if [ -e "$Q/remove" ] || [ "$gone" -ge "$GRACE" ]; then
    put removed "time=$(date +%s)"
    rm -f "$R/pid" "$R/.started.$ME"
    self_delete
    exit 0
  fi

  # Advanced ACME sets the task up again and starts it anew. It waits until
  # this instance has removed its start marker.
  if [ -e "$Q/restart" ] && [ "$Q/restart" -nt "$R/.started.$ME" ]; then
    rm -f "$R/.started.$ME"
    exit 0
  fi

  install_requests
  if [ -e "$Q/list" ] && [ "$Q/list" -nt "$R/.listed" ]; then
    list_certs
  fi

  beat=$((beat + INTERVAL))
  if [ "$beat" -ge 60 ]; then
    heartbeat
    beat=0
  fi
  sleep "$INTERVAL"
done

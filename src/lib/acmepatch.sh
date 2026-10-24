#!/bin/bash
# Small adjustment applied to every acme.sh that Advanced ACME runs (the
# bundled copy at build time and copies installed by an acme.sh update).
#
# After finalizing an order, acme.sh polls for the certificate only 30 times,
# 2 seconds apart, when the CA sends no Retry-After header. The IONOS ACME
# server (certificates by Sectigo) often needs several minutes, so acme.sh
# gave up while the order was still "processing". The patch keeps the polling
# loop but waits with the backoff acme.sh uses elsewhere (2, 5, 10, then 20
# seconds), about 9 minutes in total, and makes the number of polls
# adjustable through MAX_CERT_RETRY_TIMES.
#
# acme_patch FILE: patch FILE in place. Does nothing if acme.sh changed this
# code (for example because the behaviour was fixed upstream).
acme_patch() {
  local f="$1"
  grep -q '^  _MAX_CERT_RETRY=30$' "$f" || return 0
  sed -i \
    -e '/^  _MAX_CERT_RETRY=30$/,/Polling order status/ s/^        _sleep 2$/        _sleep "$(_retry_backoff_sec "$(_math "$_link_cert_retry" + 1)")"/' \
    -e 's/^  _MAX_CERT_RETRY=30$/  _MAX_CERT_RETRY="${MAX_CERT_RETRY_TIMES:-30}"/' \
    "$f"
}

# acme_patched FILE: the adjustment is in place.
acme_patched() { grep -q '_MAX_CERT_RETRY="${MAX_CERT_RETRY_TIMES:-30}"' "$1"; }

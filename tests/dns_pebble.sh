#!/usr/bin/env sh
# shellcheck disable=SC2034
# Test-only DNS plugin: publishes TXT records in pebble-challtestsrv.
dns_pebble_info='Pebble challenge test server
Site: github.com/letsencrypt/pebble
Options:
 PEBBLE_CHALL_URL Management URL of pebble-challtestsrv. Optional.
'

dns_pebble_add() {
  _url="${PEBBLE_CHALL_URL:-http://127.0.0.1:8055}"
  curl -s -X POST -d "{\"host\":\"$1.\",\"value\":\"$2\"}" "$_url/set-txt" >/dev/null
}

dns_pebble_rm() {
  _url="${PEBBLE_CHALL_URL:-http://127.0.0.1:8055}"
  curl -s -X POST -d "{\"host\":\"$1.\"}" "$_url/clear-txt" >/dev/null
}

#!/bin/bash
# Optional updates of acme.sh to newer official releases.
#
# The bundled acme.sh in the package is never modified. A newer release is
# installed next to the data in ${ACME_UPDATED} and used while it is newer than
# the bundled version. Advanced ACME is only tested with the bundled version,
# so the GUI marks newer versions as experimental. Removing ${ACME_UPDATED}
# returns to the bundled version.

ACME_RELEASES_API="${AACME_ACME_RELEASES_API:-https://api.github.com/repos/acmesh-official/acme.sh/releases/latest}"
# {tag} is replaced by the release tag. Assigned in two steps: a "}" inside
# ${VAR:-default} would end the expansion early.
ACME_TARBALL_URL='https://github.com/acmesh-official/acme.sh/archive/refs/tags/{tag}.tar.gz'
[ -n "${AACME_ACME_TARBALL_URL:-}" ] && ACME_TARBALL_URL="$AACME_ACME_TARBALL_URL"
ACME_UPDATE_STATE="${AACME_VAR}/acme_update.conf"

valid_release_tag() { [[ "$1" =~ ^v?[0-9]+(\.[0-9]+){1,3}$ ]]; }

# acme_latest_release: print the tag of the latest acme.sh release and cache it.
acme_latest_release() {
  local tag
  tag="$(curl -fsSL --max-time 20 -H "Accept: application/vnd.github+json" "$ACME_RELEASES_API" 2>/dev/null |
    grep -o '"tag_name" *: *"[^"]*"' | head -n1 | sed 's/.*"\([^"]*\)"$/\1/')"
  valid_release_tag "$tag" || return 1
  touch "$ACME_UPDATE_STATE"
  kv_set "$ACME_UPDATE_STATE" latest "$tag"
  kv_set "$ACME_UPDATE_STATE" checked "$(date +%s)"
  printf '%s' "$tag"
}

# used_dns_plugins: DNS plugins referenced by the managed certificates.
used_dns_plugins() {
  local conf w
  for conf in "$ACME_CFG"/*/*.conf; do
    [ -f "$conf" ] || continue
    w="$(acme_conf_get "$conf" Le_Webroot)"
    printf '%s\n' ${w//,/ }
  done | grep '^dns_' | sort -u
}

# cmd_acme_check: JSON with the latest release and whether it is an update.
cmd_acme_check() {
  local tag
  if ! tag="$(acme_latest_release)"; then
    printf '{"ok":false,"error":"acme_check_failed"}'
    return 0
  fi
  printf '{"ok":true,"latest":%s,"update_available":%s}' "$(json_str "${tag#v}")" \
    "$(json_bool "$(version_gt "${tag#v}" "$(acme_sh_version)" && echo 1)")"
}

# job_acme_update [TAG]: install the given (default: latest) acme.sh release.
job_acme_update() {
  local tag="${1:-}" tmp src ver new old url placeholder="{tag}"
  echo "@@STEP acme_update"
  if [ -z "$tag" ]; then
    echo "Looking up the latest acme.sh release..."
    if ! tag="$(acme_latest_release)"; then
      echo "Could not determine the latest acme.sh release."
      echo "@@FAIL acme_update"
      return 1
    fi
  fi
  valid_release_tag "$tag" || { echo "Invalid release tag: $tag"; echo "@@FAIL acme_update"; return 1; }
  ver="${tag#v}"
  echo "Active acme.sh: $(acme_sh_version) (bundled: $(acme_sh_version "$ACME_BUNDLED"))"
  if ! version_gt "$ver" "$(acme_sh_version)"; then
    echo "acme.sh $ver is not newer than the active version. Nothing to do."
    echo "@@INFO up_to_date"
    echo "@@DONE"
    return 0
  fi

  tmp="${AACME_VAR}/acme-sh.tmp"
  new="${AACME_VAR}/acme-sh.new"
  old="${AACME_VAR}/acme-sh.old"
  rm -rf "$tmp" "$new" "$old"
  mkdir -p "$tmp"
  url="${ACME_TARBALL_URL//"$placeholder"/$tag}"
  echo "Downloading acme.sh $ver from $url"
  if ! curl -fsSL --max-time 300 "$url" -o "$tmp/acme.tar.gz" || ! tar -xzf "$tmp/acme.tar.gz" -C "$tmp"; then
    echo "Download or extraction failed."
    rm -rf "$tmp"
    echo "@@FAIL acme_update"
    return 1
  fi
  src="$(find "$tmp" -mindepth 2 -maxdepth 2 -name acme.sh -type f | head -n1)"
  src="${src%/acme.sh}"
  # Sanity checks: right version, and the parts Advanced ACME relies on.
  if [ -z "$src" ] || [ "$(acme_sh_version "$src")" != "$ver" ] ||
    [ ! -f "$src/deploy/synology_dsm.sh" ] || [ ! -f "$src/dnsapi/dns_ionos.sh" ] ||
    ! sh "$src/acme.sh" --version >/dev/null 2>&1; then
    echo "The downloaded archive does not look like acme.sh $ver. Nothing was changed."
    rm -rf "$tmp"
    echo "@@FAIL acme_update"
    return 1
  fi
  # Every DNS plugin used by an existing certificate must still be there,
  # otherwise renewals would fail after the update.
  local plugin missing=""
  for plugin in $(used_dns_plugins); do
    [ -f "$src/dnsapi/${plugin}.sh" ] || missing="$missing $plugin"
  done
  if [ -n "$missing" ]; then
    echo "acme.sh $ver no longer contains DNS plugins used by your certificates:$missing"
    echo "Nothing was changed."
    rm -rf "$tmp"
    echo "@@FAIL acme_update"
    return 1
  fi
  mkdir -p "$new"
  cp -a "$src/acme.sh" "$src/dnsapi" "$src/deploy" "$src/notify" "$new/"
  [ -f "$src/LICENSE.md" ] && cp "$src/LICENSE.md" "$new/"
  # Our deploy hook must sit next to acme.sh's own hooks.
  cp "${ACME_BUNDLED}/deploy/advanced_acme_dsm.sh" "$new/deploy/"
  chmod 755 "$new/acme.sh"
  rm -rf "$tmp"

  [ -d "$ACME_UPDATED" ] && mv "$ACME_UPDATED" "$old"
  mv "$new" "$ACME_UPDATED"
  rm -rf "$old"
  touch "$ACME_UPDATE_STATE"
  kv_set "$ACME_UPDATE_STATE" installed "$ver"
  kv_set "$ACME_UPDATE_STATE" installed_time "$(date +%s)"
  echo "acme.sh $ver installed. Advanced ACME was tested with the bundled acme.sh $(acme_sh_version "$ACME_BUNDLED"); newer versions are experimental."
  echo "@@DONE"
  notify_admins acme_updated
  return 0
}

# cmd_acme_revert: go back to the bundled acme.sh.
cmd_acme_revert() {
  if ! lock_acquire 30; then
    printf '{"ok":false,"error":"busy"}'
    return 0
  fi
  rm -rf "$ACME_UPDATED"
  kv_del "$ACME_UPDATE_STATE" installed
  lock_release
  printf '{"ok":true,"version":%s}' "$(json_str "$(acme_sh_version "$ACME_BUNDLED")")"
}

# acme_auto_update_due: auto update enabled and last check older than a day.
acme_auto_update_due() {
  local last
  [ "$(setting acme_auto_update)" = "1" ] || return 1
  last="$(kv_get "$ACME_UPDATE_STATE" auto_checked 0)"
  [[ "$last" =~ ^[0-9]+$ ]] || last=0
  [ $(($(date +%s) - last)) -ge 86400 ]
}

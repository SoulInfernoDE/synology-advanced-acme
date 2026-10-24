#!/bin/bash
# DSM task: the alternative to a DSM account for installing certificates.
#
# For NAS that enforce 2-step verification for all administrators, Advanced
# ACME can create a task "Advanced ACME" in the DSM Task Scheduler. It runs
# as root and imports certificates locally with synowebapi, the way DSM
# installs its own Let's Encrypt certificates. Creating it needs an
# administrator sign-in once; nothing of that sign-in is stored.
#
# The task is a triggered task (event "boot-up"): DSM starts it at boot and
# Advanced ACME starts it once when it sets it up. It then stays in the
# background and looks for requests every few seconds without touching the
# disks, so they can go to sleep. (Script version 1 was a scheduled task that
# ran every minute; DSM records every run on the system partition.)
#
# The task's script (share/dsm-task.sh) is stored in the task itself and only
# reads data from the package folder, so the package user cannot change what
# runs as root. Requests go to $AACME_TASK_Q/queue, results come back in
# $AACME_TASK_RUN (owned by root). The task deletes itself when the package
# is uninstalled or when $AACME_TASK_Q/remove exists.

AACME_TASK_Q="${AACME_VAR}/dsm-task"
AACME_TASK_RUN="${AACME_TASK_RUN:-/run/advanced-acme}"
AACME_TASK_CONF="${AACME_TASK_Q}/task.conf"
AACME_TASK_INTERVAL="${AACME_TASK_INTERVAL:-5}"
# A package update replaces the package folder only for a moment.
AACME_TASK_GRACE="${AACME_TASK_GRACE:-120}"
TASK_NAME="Advanced ACME"
TASK_SCRIPT_VERSION=2

task_configured() { [ -f "$AACME_TASK_CONF" ]; }

# task_script: the root script with this NAS's paths filled in.
task_script() {
  sed -e "s|@QUEUE@|${AACME_TASK_Q}|g" -e "s|@RUN@|${AACME_TASK_RUN}|g" \
    -e "s|@SYNOWEBAPI@|${AACME_SYNOWEBAPI:-/usr/syno/bin/synowebapi}|g" \
    -e "s|@PKGDIR@|${AACME_TASK_PKGDIR:-/var/packages/${AACME_PKG}}|g" \
    -e "s|@NAME@|${TASK_NAME}|g" -e "s|@SCRIPT_VERSION@|${TASK_SCRIPT_VERSION}|g" \
    -e "s|@INTERVAL@|${AACME_TASK_INTERVAL}|g" -e "s|@GRACE@|${AACME_TASK_GRACE}|g" \
    "${AACME_TARGET}/share/dsm-task.sh"
}

task_heartbeat() { kv_get "${AACME_TASK_RUN}/heartbeat" "$1"; }

# task_wait_heartbeat SINCE SECONDS: wait for a sign of life after SINCE.
task_wait_heartbeat() {
  local since="$1" i t
  for i in $(seq 1 "$2"); do
    t="$(task_heartbeat time)"
    [[ "$t" =~ ^[0-9]+$ ]] && [ "$t" -ge "$since" ] && return 0
    sleep 1
  done
  return 1
}

# task_alive: the task gave a sign of life recently (it does so every minute).
task_alive() {
  local t
  t="$(task_heartbeat time)"
  [[ "$t" =~ ^[0-9]+$ ]] && [ $(($(date +%s) - t)) -le 180 ]
}

# task_find_id: id of a scheduled task of script version 1 in the current
# administrator session. The list also contains triggered tasks (type
# "event_script"), so only scheduled scripts count.
task_find_id() {
  DSM_API_VERSION=3 dsm_call SYNO.Core.TaskScheduler list offset=0 limit=-1 |
    jq -r --arg n "$TASK_NAME" '[.data.tasks[]? | select(.name == $n and .owner == "root" and .type == "script")][0].id // empty' 2>/dev/null
}

# task_exists: the triggered task is set up in DSM (administrator session).
task_exists() {
  [ "$(DSM_API_VERSION=1 dsm_call SYNO.Core.EventScheduler get "task_name=$(json_str "$TASK_NAME")" |
    jq -r '.data.task_name // empty' 2>/dev/null)" = "$TASK_NAME" ]
}

# cmd_dsm_create_task USER PASS [OTP]: create (or update) the DSM task with a
# one-time administrator sign-in and switch to it.
cmd_dsm_create_task() {
  local admin="$1" apass="$2" otp="$3" resp token id old method started i
  if [ -z "$admin" ] || [ -z "$apass" ]; then
    printf '{"ok":false,"error":"dsm_no_credentials"}'
    return 0
  fi
  if ! DSM_LAN=1 DSM_NO_DEVICE=1 dsm_login "$admin" "$apass" "$otp"; then
    printf '{"ok":false,"error":"dsm_auth_%s"}' "$(json_escape "$DSM_ERR")"
    return 0
  fi
  # DSM asks for the password again before it saves a task that runs as root.
  resp="$(DSM_API_VERSION=2 dsm_call SYNO.Core.User.PasswordConfirm auth "password=$(json_str "$apass")")"
  token="$(json_field "$resp" SynoConfirmPWToken)"
  if [ -z "$token" ]; then
    dsm_logout
    printf '{"ok":false,"error":"dsm_task_confirm","code":%s}' "$(json_str "$(dsm_error_code "$resp")")"
    return 0
  fi
  rm -f "${AACME_TASK_Q}/remove"
  mkdir -p "${AACME_TASK_Q}/queue"
  local args=("task_name=$(json_str "$TASK_NAME")" 'owner={"0":"root"}' 'event="bootup"' enable=true
    'depend_on_task=""' notify_enable=false 'notify_mail=""' notify_if_error=false 'operation_type="script"'
    "SynoConfirmPWToken=$(json_str "$token")")
  method=set
  resp='{"success":true}'
  # DSM 7.2 aborts "create" with a script of a few kilobytes but stores it
  # with "set": create the task with a placeholder first.
  if ! task_exists; then
    method=create
    resp="$(DSM_API_VERSION=1 dsm_call SYNO.Core.EventScheduler.Root create "${args[@]}" 'operation="exit 0"')"
  fi
  dsm_ok "$resp" && resp="$(DSM_API_VERSION=1 dsm_call SYNO.Core.EventScheduler.Root set "${args[@]}" \
    "old_task_name=$(json_str "$TASK_NAME")" "operation=$(task_script | jq -Rs .)")"
  if ! dsm_ok "$resp"; then
    dsm_logout
    printf '{"ok":false,"error":"dsm_task_create","code":%s}' "$(json_str "$(dsm_error_code "$resp")")"
    return 0
  fi
  [ "$method" = set ] && activity_log dsm_task_updated name "$TASK_NAME" || activity_log dsm_task_created name "$TASK_NAME"
  # Script version 1 was a scheduled task of the same name; it is replaced.
  id="$(task_find_id)"
  if [ -n "$id" ]; then
    DSM_API_VERSION=2 dsm_call SYNO.Core.TaskScheduler delete "tasks=[{\"id\":${id},\"real_owner\":\"root\"}]" \
      "SynoConfirmPWToken=$(json_str "$token")" >/dev/null
  fi
  # DSM does not start a task that is still running: ask a running instance
  # to end (it removes its start marker), then start the new script.
  old="$(task_heartbeat pid)"
  : >"${AACME_TASK_Q}/restart"
  if [[ "$old" =~ ^[0-9]+$ ]]; then
    for i in $(seq 1 $((AACME_TASK_INTERVAL * 3 + 5))); do
      [ -e "${AACME_TASK_RUN}/.started.${old}" ] || break
      sleep 1
    done
  fi
  # DSM notes the end of the old instance a moment later and ignores "run"
  # until then: try again until the new instance reports.
  started="$(date +%s)"
  for i in 1 2 3 4 5; do
    DSM_API_VERSION=1 dsm_call SYNO.Core.EventScheduler run "task_name=$(json_str "$TASK_NAME")" >/dev/null
    task_wait_heartbeat "$started" 6 && break
  done
  dsm_logout

  rm -f "$AACME_TASK_CONF"
  kv_set "$AACME_TASK_CONF" version "$TASK_SCRIPT_VERSION"
  kv_set "$AACME_TASK_CONF" created "$started"
  # The task replaces a stored DSM account.
  if [ -f "$DSM_CONF" ]; then
    if [ "$(kv_get "$DSM_CONF" managed)" = 1 ]; then
      dsm_remove_service
    else
      activity_log dsm_account_forgotten user "$(kv_get "$DSM_CONF" user)"
    fi
    rm -f "$DSM_CONF"
  fi

  if ! task_wait_heartbeat "$started" 45; then
    printf '{"ok":false,"error":"dsm_task_no_run"}'
    return 0
  fi
  if [ -n "$(task_heartbeat error)" ]; then
    printf '{"ok":false,"error":"dsm_task_%s"}' "$(json_escape "$(task_heartbeat error)")"
    return 0
  fi
  printf '{"ok":true,"mode":"task","dsm":{"data":%s}}' "$(task_certs_json)"
}

task_certs_json() {
  local j
  j="$(cat "${AACME_TASK_RUN}/certs.json" 2>/dev/null)"
  case "$j" in \{*\}) printf '%s' "$j" ;; *) printf '{"certificates":[]}' ;; esac
}

# task_certs_json_fresh: ask the running task for a current certificate list
# (it no longer refreshes it on its own) and print it.
task_certs_json_fresh() {
  local i
  if task_alive; then
    : >"${AACME_TASK_Q}/list"
    for i in $(seq 1 $((AACME_TASK_INTERVAL * 2 + 5))); do
      [ "${AACME_TASK_RUN}/.listed" -nt "${AACME_TASK_Q}/list" ] && break
      sleep 1
    done
  fi
  task_certs_json
}

# task_remove: ask the task to delete itself (it checks every few seconds).
task_remove() {
  task_configured || return 0
  : >"${AACME_TASK_Q}/remove"
  rm -f "$AACME_TASK_CONF" "${AACME_TASK_Q}"/queue/*.req
  activity_log dsm_task_remove_requested name "$TASK_NAME"
}

cmd_dsm_task_remove() {
  task_remove
  printf '{"ok":true}'
}

# task_collect: pick up results of the DSM task, log them and clean up.
task_collect() {
  local req name nonce result status code meta removed
  for req in "${AACME_TASK_Q}"/queue/*.req; do
    [ -f "$req" ] || continue
    name="$(basename "$req" .req)"
    # The task skips names it does not accept (0.1.7 and earlier queued
    # wildcard certificates as "*.domain"); such a request would wait forever.
    if [[ ! "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then
      rm -f "$req"
      continue
    fi
    result="${AACME_TASK_RUN}/${name}.result"
    nonce="$(kv_get "$req" nonce)"
    [ -n "$nonce" ] && [ "$(kv_get "$result" nonce)" = "$nonce" ] || continue
    status="$(kv_get "$result" status)"
    code="$(kv_get "$result" code)"
    meta="$(meta_file "$(kv_get "$req" domain)")"
    if [ -f "$meta" ]; then
      kv_set "$meta" deploy_status "$status"
      kv_set "$meta" deploy_error "$code"
      kv_set "$meta" deploy_time "$(kv_get "$result" time)"
    fi
    if [ "$status" = ok ]; then
      activity_log dsm_task_installed cert "$(kv_get "$req" domain)"
    else
      activity_log dsm_task_install_failed cert "$(kv_get "$req" domain)" code "$code"
    fi
    rm -f "$req"
  done
  # The task confirmed that it deletes itself. The marker stays, so a task that
  # could not delete itself tries again; creating a task clears it.
  removed="$(kv_get "${AACME_TASK_RUN}/removed" time)"
  # The package was uninstalled with the data kept: the task deleted itself
  # after it was created, so it is no longer set up.
  if task_configured && [[ "$removed" =~ ^[0-9]+$ ]] &&
    [ "$removed" -ge "$(kv_get "$AACME_TASK_CONF" created 0)" ]; then
    rm -f "$AACME_TASK_CONF"
    activity_log dsm_task_removed name "$TASK_NAME"
    return 0
  fi
  if [ -f "${AACME_TASK_Q}/remove" ] && [ "$(kv_get "${AACME_TASK_Q}/remove" logged)" != 1 ] &&
    [[ "$removed" =~ ^[0-9]+$ ]] && [ "$removed" -ge "$(stat -c %Y "${AACME_TASK_Q}/remove")" ]; then
    kv_set "${AACME_TASK_Q}/remove" logged 1
    activity_log dsm_task_removed name "$TASK_NAME"
  fi
  return 0
}

# task_status_json: state of the DSM task for the GUI.
task_status_json() {
  local last version error
  last="$(task_heartbeat time)"
  version="$(task_heartbeat version)"
  error="$(task_heartbeat error)"
  printf '{"configured":%s,"name":%s,"last_run":%s,"version":%s,"current_version":%s,"error":%s,"removing":%s}' \
    "$(json_bool "$(task_configured && echo 1)")" "$(json_str "$TASK_NAME")" "$(json_num "$last")" \
    "$(json_num "$version")" "$TASK_SCRIPT_VERSION" "$(json_str "$error")" \
    "$(json_bool "$([ -f "${AACME_TASK_Q}/remove" ] && [ "$(kv_get "${AACME_TASK_Q}/remove" logged)" != 1 ] && echo 1)")"
}

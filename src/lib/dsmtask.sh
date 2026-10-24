#!/bin/bash
# DSM task: the alternative to a DSM account for installing certificates.
#
# For NAS that enforce 2-step verification for all administrators, Advanced
# ACME can create a task "Advanced ACME" in the DSM Task Scheduler. It runs
# as root every minute and imports certificates locally with synowebapi, the
# way DSM installs its own Let's Encrypt certificates. Creating it needs an
# administrator sign-in once; nothing of that sign-in is stored.
#
# The task's script (share/dsm-task.sh) is stored in the task itself and only
# reads data from the package folder, so the package user cannot change what
# runs as root. Requests go to $AACME_TASK_Q/queue, results come back in
# $AACME_TASK_RUN (owned by root). The task deletes itself when the package
# is uninstalled or when $AACME_TASK_Q/remove exists.

AACME_TASK_Q="${AACME_VAR}/dsm-task"
AACME_TASK_RUN="${AACME_TASK_RUN:-/run/advanced-acme}"
AACME_TASK_CONF="${AACME_TASK_Q}/task.conf"
TASK_NAME="Advanced ACME"
TASK_SCRIPT_VERSION=1

task_configured() { [ -f "$AACME_TASK_CONF" ]; }

# task_script: the root script with this NAS's paths filled in.
task_script() {
  sed -e "s|@QUEUE@|${AACME_TASK_Q}|g" -e "s|@RUN@|${AACME_TASK_RUN}|g" \
    -e "s|@SYNOWEBAPI@|${AACME_SYNOWEBAPI:-/usr/syno/bin/synowebapi}|g" \
    -e "s|@PKGDIR@|${AACME_TASK_PKGDIR:-/var/packages/${AACME_PKG}}|g" \
    -e "s|@NAME@|${TASK_NAME}|g" -e "s|@SCRIPT_VERSION@|${TASK_SCRIPT_VERSION}|g" \
    "${AACME_TARGET}/share/dsm-task.sh"
}

task_heartbeat() { kv_get "${AACME_TASK_RUN}/heartbeat" "$1"; }

# task_wait_heartbeat SINCE SECONDS: wait for a task run after SINCE.
task_wait_heartbeat() {
  local since="$1" i t
  for i in $(seq 1 "$2"); do
    t="$(task_heartbeat time)"
    [[ "$t" =~ ^[0-9]+$ ]] && [ "$t" -ge "$since" ] && return 0
    sleep 1
  done
  return 1
}

# task_find_id: id of our task in the current administrator session.
task_find_id() {
  DSM_API_VERSION=3 dsm_call SYNO.Core.TaskScheduler list offset=0 limit=-1 |
    jq -r --arg n "$TASK_NAME" '[.data.tasks[]? | select(.name == $n and .owner == "root")][0].id // empty' 2>/dev/null
}

# cmd_dsm_create_task USER PASS [OTP]: create (or update) the DSM task with a
# one-time administrator sign-in and switch to it.
cmd_dsm_create_task() {
  local admin="$1" apass="$2" otp="$3" resp token id sched extra started
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
  sched="$(printf '{"date_type":0,"week_day":"0,1,2,3,4,5,6","hour":0,"minute":0,"repeat_hour":0,"repeat_min":1,"last_work_hour":23,"monthly_week":[],"repeat_date":1001,"date":"%s"}' "$(date +%Y/%m/%d)")"
  extra="$(task_script | jq -Rs '{script: .}')"
  id="$(task_find_id)"
  local args=("name=$(json_str "$TASK_NAME")" 'owner="root"' enable=true 'type="script"' "schedule=$sched"
    "extra=$extra" "SynoConfirmPWToken=$(json_str "$token")")
  if [ -n "$id" ]; then
    resp="$(DSM_API_VERSION=4 dsm_call SYNO.Core.TaskScheduler.Root set "id=$id" "${args[@]}")"
  else
    resp="$(DSM_API_VERSION=4 dsm_call SYNO.Core.TaskScheduler.Root create "${args[@]}")"
  fi
  if ! dsm_ok "$resp"; then
    dsm_logout
    printf '{"ok":false,"error":"dsm_task_create","code":%s}' "$(json_str "$(dsm_error_code "$resp")")"
    return 0
  fi
  [ -n "$id" ] && activity_log dsm_task_updated name "$TASK_NAME" || activity_log dsm_task_created name "$TASK_NAME"
  [ -n "$id" ] || id="$(printf '%s' "$resp" | jq -r '.data.id // empty')"
  # Run it once now to check that it works.
  started="$(date +%s)"
  DSM_API_VERSION=2 dsm_call SYNO.Core.TaskScheduler run "tasks=[{\"id\":${id:-0},\"real_owner\":\"root\"}]" >/dev/null
  dsm_logout

  rm -f "$AACME_TASK_CONF"
  kv_set "$AACME_TASK_CONF" id "$id"
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

# task_remove: ask the task to delete itself (it runs every minute).
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

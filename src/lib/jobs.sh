#!/bin/bash
# Background jobs: long acme.sh runs (issue, renew, deploy, expert commands)
# are detached from the CGI request. The GUI polls the job log.
#
# Log lines starting with "@@" are progress markers for the GUI:
#   @@STEP <name>   a new phase begins
#   @@FAIL <name>   the phase failed
#   @@DONE          everything succeeded

job_new_id() {
  printf '%s-%s' "$(date +%Y%m%d%H%M%S)" "$$"
}

job_cleanup_old() {
  # Keep the 40 most recent jobs.
  local old
  old="$(ls -1t "$AACME_JOBS"/*.state 2>/dev/null | tail -n +41)"
  [ -n "$old" ] || return 0
  printf '%s\n' "$old" | while IFS= read -r f; do
    rm -f "$f" "${f%.state}.log" "${f%.state}.info" "${f%.state}.pid"
  done
}

# job_spawn TYPE LABEL -- ARGS...: start "advanced-acme _job TYPE ID ARGS..." detached.
# Secrets are handed over in the environment, never on the command line.
job_prepare() {
  local type="$1" label="$2" id
  id="$(job_new_id)"
  job_cleanup_old
  printf 'type=%s\nlabel=%s\nstarted=%s\n' "$type" "$label" "$(date +%s)" >"${AACME_JOBS}/${id}.info"
  echo "queued" >"${AACME_JOBS}/${id}.state"
  : >"${AACME_JOBS}/${id}.log"
  printf '%s' "$id"
}

job_spawn() {
  local type="$1" label="$2" id
  shift 2
  [ "$1" = "--" ] && shift
  id="$(job_prepare "$type" "$label")"
  if command -v setsid >/dev/null 2>&1; then
    setsid "${AACME_TARGET}/bin/advanced-acme" _job "$type" "$id" "$@" </dev/null >/dev/null 2>&1 &
  else
    nohup "${AACME_TARGET}/bin/advanced-acme" _job "$type" "$id" "$@" </dev/null >/dev/null 2>&1 &
  fi
  printf '%s' "$id"
}

valid_job_id() { [[ "$1" =~ ^[0-9]{14}-[0-9]+$ ]]; }

# job_run TYPE ID ARGS...: executed in the detached process.
job_run() {
  local type="$1" id="$2" rc log
  shift 2
  log="${AACME_JOBS}/${id}.log"
  exec >>"$log" 2>&1
  echo "$$" >"${AACME_JOBS}/${id}.pid"
  echo "waiting" >"${AACME_JOBS}/${id}.state"
  if ! lock_acquire 3600; then
    echo "@@FAIL lock"
    echo "done 1" >"${AACME_JOBS}/${id}.state"
    return 1
  fi
  echo "running" >"${AACME_JOBS}/${id}.state"
  # Another job may have installed or removed an acme.sh update meanwhile.
  acme_select_home
  case "$type" in
    register) job_register "$@" ;;
    issue) job_issue "$@" ;;
    renew) job_renew "$@" ;;
    deploy) job_deploy "$@" ;;
    expert) job_expert "$@" ;;
    cron) job_cron "$@" ;;
    acme_update) job_acme_update "$@" ;;
    *) echo "unknown job type"; false ;;
  esac
  rc=$?
  task_collect
  lock_release
  echo "done $rc" >"${AACME_JOBS}/${id}.state"
  rm -f "${AACME_JOBS}/${id}.pid"
  return "$rc"
}

# job_reap ID: a job whose process is gone without finishing (NAS restart,
# killed process) is marked as failed, so the GUI does not wait forever.
job_reap() {
  local id="$1" state pid
  state="$(cat "${AACME_JOBS}/${id}.state" 2>/dev/null)"
  case "$state" in waiting | running) ;; *) return 0 ;; esac
  pid="$(cat "${AACME_JOBS}/${id}.pid" 2>/dev/null)"
  if [ -n "$pid" ]; then
    kill -0 "$pid" 2>/dev/null && return 0
  else
    # Jobs of early beta builds have no pid file: give up after 2 hours.
    local started
    started="$(kv_get "${AACME_JOBS}/${id}.info" started 0)"
    [[ "$started" =~ ^[0-9]+$ ]] || started=0
    [ $(($(date +%s) - started)) -gt 7200 ] || return 0
  fi
  printf 'The task was interrupted (for example by a restart of the NAS).\n@@FAIL interrupted\n' >>"${AACME_JOBS}/${id}.log"
  echo "done 1" >"${AACME_JOBS}/${id}.state"
  rm -f "${AACME_JOBS}/${id}.pid"
}

cmd_job_status() {
  local id="$1" state info
  if ! valid_job_id "$id" || [ ! -f "${AACME_JOBS}/${id}.state" ]; then
    printf '{"ok":false,"error":"job_not_found"}'
    return 0
  fi
  job_reap "$id"
  state="$(cat "${AACME_JOBS}/${id}.state")"
  info="${AACME_JOBS}/${id}.info"
  printf '{"ok":true,"id":%s,"type":%s,"label":%s,"state":%s,"rc":%s,"log":%s}' \
    "$(json_str "$id")" "$(json_str "$(kv_get "$info" type)")" "$(json_str "$(kv_get "$info" label)")" \
    "$(json_str "${state%% *}")" "$(json_num "${state#done }")" "$(json_file_str "${AACME_JOBS}/${id}.log")"
}

cmd_jobs() {
  local first=1 f id info state
  printf '{"ok":true,"jobs":['
  for f in $(ls -1t "$AACME_JOBS"/*.state 2>/dev/null | head -n 20); do
    id="$(basename "$f" .state)"
    info="${AACME_JOBS}/${id}.info"
    job_reap "$id"
    state="$(cat "$f")"
    [ "$first" = 1 ] || printf ','
    first=0
    printf '{"id":%s,"type":%s,"label":%s,"started":%s,"state":%s,"rc":%s}' \
      "$(json_str "$id")" "$(json_str "$(kv_get "$info" type)")" "$(json_str "$(kv_get "$info" label)")" \
      "$(json_num "$(kv_get "$info" started)")" "$(json_str "${state%% *}")" "$(json_num "${state#done }")"
  done
  printf ']}'
}

# --- Job implementations ------------------------------------------------------

# cert_ready CERT_ID: the issued certificate and key exist (the synology_dsm
# hook would otherwise upload empty files and still report success).
cert_ready() {
  local id="$1" domain="${1%_ecc}"
  [ -s "${ACME_CFG}/${id}/${domain}.cer" ] && [ -s "${ACME_CFG}/${id}/${domain}.key" ]
}

# register SERVER EMAIL  (EAB values come from AACME_EAB_KID / AACME_EAB_HMAC)
job_register() {
  local server="$1" email="$2" args
  args=(--register-account --server "$server")
  echo "@@STEP register"
  [ -n "$email" ] && args+=(--accountemail "$email")
  if [ -n "${AACME_EAB_KID:-}" ]; then
    args+=(--eab-kid "$AACME_EAB_KID" --eab-hmac-key "$AACME_EAB_HMAC")
  fi
  if acme "${args[@]}"; then
    echo "@@DONE"
    return 0
  fi
  echo "@@FAIL register"
  return 1
}

# issue SERVER PLUGIN KEYLENGTH DSM_DESC_B64 FORCE PROVIDER DOMAIN...
# DNS plugin credentials are already exported in the environment.
job_issue() {
  local server="$1" plugin="$2" keylength="$3" desc_b64="$4" force="$5" provider="$6" rc main ecc=() meta days
  shift 6
  main="$1"
  days="$(setting renew_before_days)"
  [[ "$days" =~ ^[0-9]+$ ]] || days=30
  local args=(--issue --server "$server" --dns "$plugin" --keylength "$keylength" --days "-${days}")
  local d
  for d in "$@"; do args+=(-d "$d"); done
  [ "$force" = 1 ] && args+=(--force)
  case "$keylength" in ec-*) ecc=(--ecc) ;; esac

  meta="$(meta_file "$main")"
  touch "$meta"
  kv_set "$meta" provider "$provider"
  kv_set "$meta" dsm_desc_b64 "$desc_b64"
  kv_set "$meta" created_by gui

  echo "@@STEP issue"
  acme "${args[@]}"
  rc=$?
  [ "$rc" = 0 ] || [ "$rc" = 2 ] && dns_save_env "$plugin"
  if [ "$rc" = 2 ]; then
    echo "@@INFO already_valid"
  elif [ "$rc" != 0 ]; then
    echo "@@FAIL issue"
    notify_admins issue_failed
    return 1
  fi

  echo "@@STEP deploy"
  if ! cert_ready "${main}${ecc:+_ecc}"; then
    echo "No certificate file found for ${main}."
    echo "@@FAIL deploy"
    return 1
  fi
  if ! acme --deploy -d "$main" "${ecc[@]}" --deploy-hook advanced_acme_dsm; then
    echo "@@FAIL deploy"
    notify_admins deploy_failed
    return 1
  fi
  echo "@@DONE"
  notify_admins issued
  return 0
}

# renew CERT_ID
job_renew() {
  local id="$1" domain ecc=()
  domain="${id%_ecc}"
  [ "$domain" != "$id" ] && ecc=(--ecc)
  echo "@@STEP renew"
  # acme.sh runs the saved deploy hook after a successful renewal.
  if acme --renew -d "$domain" "${ecc[@]}" --force; then
    echo "@@DONE"
    return 0
  fi
  echo "@@FAIL renew"
  notify_admins renew_failed
  return 1
}

# deploy CERT_ID
job_deploy() {
  local id="$1" domain ecc=()
  domain="${id%_ecc}"
  [ "$domain" != "$id" ] && ecc=(--ecc)
  echo "@@STEP deploy"
  if ! cert_ready "$id"; then
    echo "No certificate file found for ${domain}. Renew the certificate first."
    echo "@@FAIL deploy"
    return 1
  fi
  if acme --deploy -d "$domain" "${ecc[@]}" --deploy-hook advanced_acme_dsm; then
    echo "@@DONE"
    return 0
  fi
  echo "@@FAIL deploy"
  return 1
}

# expert ARGS...: raw acme.sh call from the expert console.
job_expert() {
  echo "@@STEP expert"
  echo "\$ acme.sh $*"
  if acme "$@"; then
    echo "@@DONE"
    return 0
  fi
  echo "@@FAIL expert"
  return 1
}

# cron: the scheduled renewal run (also used by the service loop).
job_cron() {
  local rc
  echo "@@STEP cron"
  acme --cron
  rc=$?
  date +%s >"${AACME_VAR}/last_cron"
  echo "$rc" >"${AACME_VAR}/last_cron_rc"
  if [ "$rc" = 0 ]; then
    echo "@@DONE"
    return 0
  fi
  echo "@@FAIL cron"
  notify_admins renew_failed
  return 1
}

#!/bin/bash
# Package status and settings, shared by the CLI and the web API.

cmd_status() {
  local svc=false pid last rc
  pid="$(cat "${AACME_VAR}/service.pid" 2>/dev/null)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && svc=true
  last="$(cat "${AACME_VAR}/last_cron" 2>/dev/null)"
  rc="$(cat "${AACME_VAR}/last_cron_rc" 2>/dev/null)"
  printf '{"ok":true,"version":%s,"acme_version":%s,"service_running":%s,"last_cron":%s,"last_cron_rc":%s,"busy":%s,' \
    "$(json_str "$(aacme_version)")" "$(json_str "$(acme_sh_version)")" "$svc" "$(json_num "$last")" \
    "$(json_num "$rc")" "$(json_bool "$(lock_busy && echo 1)")"
  task_collect
  local mode=none
  dsm_has_credentials && mode=account
  task_configured && mode=task
  printf '"dsm":{"configured":%s,"mode":%s,"task":%s,"user":%s,"managed":%s,"two_factor_token":%s},' \
    "$(json_bool "$([ "$mode" != none ] && echo 1)")" "$(json_str "$mode")" "$(task_status_json)" \
    "$(json_str "$(kv_get "$DSM_CONF" user)")" \
    "$(json_bool "$([ "$(kv_get "$DSM_CONF" managed)" = 1 ] && echo 1)")" \
    "$(json_bool "$([ -n "$(kv_get "$DSM_CONF" device_id)" ] && echo 1)")"
  printf '"settings":{"renew_before_days":%s,"notify":%s,"dsm_host":%s,"dsm_scheme":%s,"dsm_port":%s,"acme_auto_update":%s},' \
    "$(json_num "$(setting renew_before_days)")" "$(json_bool "$(setting notify)")" \
    "$(json_str "$(setting dsm_host)")" "$(json_str "$(setting dsm_scheme)")" "$(json_str "$(setting dsm_port)")" \
    "$(json_bool "$(setting acme_auto_update)")"
  printf '"acme":{"active":%s,"bundled":%s,"updated":%s,"latest":%s,"checked":%s},' \
    "$(json_str "$(acme_sh_version)")" "$(json_str "$(acme_sh_version "$ACME_BUNDLED")")" \
    "$(json_bool "$([ "$ACME_HOME" = "$ACME_UPDATED" ] && echo 1)")" \
    "$(json_str "$(kv_get "$ACME_UPDATE_STATE" latest | sed 's/^v//')")" "$(json_num "$(kv_get "$ACME_UPDATE_STATE" checked)")"
  printf '"paths":{"var":%s,"acme_home":%s,"acme_config":%s,"cli":"/usr/local/bin/advanced-acme"}}' \
    "$(json_str "$AACME_VAR")" "$(json_str "$ACME_HOME")" "$(json_str "$ACME_CFG")"
}

# cmd_set KEY VALUE: whitelisted settings only.
cmd_set() {
  local key="$1" val="$2"
  case "$key" in
    renew_before_days) [[ "$val" =~ ^[0-9]{1,3}$ ]] && [ "$val" -ge 1 ] && [ "$val" -le 120 ] || val="" ;;
    notify | acme_auto_update) [[ "$val" =~ ^[01]$ ]] || val="" ;;
    dsm_scheme) [[ "$val" =~ ^(http|https)?$ ]] || val="x" ;;
    dsm_port) [[ "$val" =~ ^[0-9]{0,5}$ ]] || val="x" ;;
    dsm_host) [[ "$val" =~ ^[A-Za-z0-9.:-]{0,253}$ ]] || val="x" ;;
    *) val="x" ;;
  esac
  if [ "$val" = "x" ] || { [ -z "$val" ] && [[ "$key" =~ ^(renew_before_days|notify|acme_auto_update)$ ]]; }; then
    printf '{"ok":false,"error":"invalid_setting"}'
    return 0
  fi
  touch "$AACME_SETTINGS"
  if [ -z "$val" ]; then
    kv_del "$AACME_SETTINGS" "$key"
  else
    kv_set "$AACME_SETTINGS" "$key" "$val"
  fi
  printf '{"ok":true}'
}

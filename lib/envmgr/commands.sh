#!/usr/bin/env bash
# Command implementations.

envmgr_parse_category() {
  case "${1:-}" in
    config|package|system) printf '%s\n' "$1" ;;
    *) envmgr_usage_error "unknown category: $1 (expected config, package, or system)" ;;
  esac
}

envmgr_cmd_init() {
  local data=""
  local new=false
  local from=""
  local machine=""
  local machine_dir=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --data)
        [[ $# -ge 2 ]] || envmgr_usage_error "--data requires a path"
        data="$2"
        shift 2
        ;;
      --new)
        new=true
        shift
        ;;
      --from)
        [[ $# -ge 2 ]] || envmgr_usage_error "--from requires a machine ID"
        from="$2"
        shift 2
        ;;
      -*) envmgr_usage_error "unknown option for init: $1" ;;
      *)
        [[ -z "$machine" ]] || envmgr_usage_error "init takes one machine ID"
        machine="$1"
        shift
        ;;
    esac
  done
  [[ -n "$machine" ]] || envmgr_usage_error "init requires a machine ID"
  envmgr_valid_machine_id "$machine" || envmgr_usage_error "invalid machine ID: $machine"
  [[ -z "$from" || "$new" == true ]] || envmgr_usage_error "--from requires --new"

  if [[ -n "$data" ]]; then
    data="$(cd -- "$(envmgr_expand_path "$data")" && pwd)" || \
      envmgr_die 1 "data repository not found: $data"
    [[ -d "$data/machines" ]] || envmgr_die 1 "data repository has no machines/ directory: $data"
    envmgr_kv_set "$(envmgr_local_config_file)" data "$data"
  fi
  data="$(envmgr_data_dir)"
  machine_dir="$(envmgr_machine_dir "$data" "$machine")"

  if [[ "$new" == true ]]; then
    envmgr_create_machine "$data" "$machine" "$from"
  fi
  [[ -d "$machine_dir" ]] || \
    envmgr_die 1 "machine does not exist: $machine (use 'envmgr init --new $machine' to create it)"
  envmgr_verify_machine "$machine_dir" refuse

  envmgr_kv_set "$(envmgr_local_config_file)" machine "$machine"
  envmgr_write_chezmoi_config "$machine_dir"
  printf 'Selected machine %s. Run envmgr check, then envmgr restore.\n' "$machine"
}

envmgr_create_machine() {
  local data="$1"
  local machine="$2"
  local from="$3"
  local machine_dir=""
  local from_dir=""
  local item=""

  machine_dir="$(envmgr_machine_dir "$data" "$machine")"
  [[ ! -e "$machine_dir" ]] || envmgr_die 1 "machine already exists: $machine"
  envmgr_detect_platform

  if [[ -n "$from" ]]; then
    from_dir="$(envmgr_machine_dir "$data" "$from")"
    [[ -d "$from_dir" ]] || envmgr_die 1 "source machine does not exist: $from"
    envmgr_verify_machine "$from_dir" refuse
  fi

  mkdir -p -- "$machine_dir"
  {
    printf 'os=%s\n' "$ENVMGR_OS"
    printf 'distribution=%s\n' "$ENVMGR_DISTRIBUTION"
    printf 'architecture=%s\n' "$ENVMGR_ARCHITECTURE"
    printf 'description=\n'
  } >"$machine_dir/machine.conf"

  if [[ -n "$from" ]]; then
    for item in config packages system SPEC.md; do
      [[ -e "$from_dir/$item" ]] && cp -pR -- "$from_dir/$item" "$machine_dir/"
    done
    printf 'Created machine %s from %s.\n' "$machine" "$from"
  else
    printf '# %s\n\nDescribe this machine and its intended configuration.\n' \
      "$machine" >"$machine_dir/SPEC.md"
    printf 'Created empty machine %s.\n' "$machine"
  fi
  mkdir -p -- "$machine_dir/config" "$machine_dir/packages" "$machine_dir/system"
}

envmgr_cmd_check() {
  local category=""
  local offline=false
  local machine_dir=""
  local machine=""
  local result=0
  local rc=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --offline) offline=true ;;
      -*) envmgr_usage_error "unknown option for check: $1" ;;
      *)
        [[ -z "$category" ]] || envmgr_usage_error "check takes at most one category"
        category="$(envmgr_parse_category "$1")"
        ;;
    esac
    shift
  done
  # Metadata refresh is part of package checks, which are not implemented yet.
  : "$offline"

  machine_dir="$(envmgr_active_machine_dir warn)"
  machine="$(basename -- "$machine_dir")"

  # Every check refreshes config, the only implemented category. Package and
  # system checks will share this path once implemented.
  rc=0
  if [[ -z "$category" || "$category" == config ]]; then
    envmgr_check_config "$machine_dir" || rc=$?
  else
    envmgr_check_config "$machine_dir" >/dev/null || rc=$?
  fi
  case "$rc" in
    0) ;;
    "$ENVMGR_EXIT_DRIFT") result="$ENVMGR_EXIT_DRIFT" ;;
    *) exit "$rc" ;;
  esac
  if [[ -n "$category" && "$category" != config ]]; then
    envmgr_warn "$category checks are not implemented yet"
    result=0
  elif [[ -z "$category" ]]; then
    envmgr_warn "package and system checks are not implemented yet"
  fi

  envmgr_refresh_summary "$machine"
  return "$result"
}

envmgr_cmd_list() {
  local category=""
  local machine_dir=""

  if [[ $# -gt 1 ]]; then
    envmgr_usage_error "list takes at most one category"
  elif [[ $# -eq 1 ]]; then
    category="$(envmgr_parse_category "$1")"
  fi
  machine_dir="$(envmgr_active_machine_dir warn)"

  if [[ -z "$category" || "$category" == config ]]; then
    [[ -z "$category" ]] && printf '# config\n'
    envmgr_list_config "$machine_dir"
  fi
  if [[ -n "$category" && "$category" != config ]]; then
    envmgr_warn "listing $category is not implemented yet"
  fi
}

# Refresh the config result and marker after a command changed config state.
envmgr_refresh_config_check() {
  local machine_dir="$1"

  envmgr_check_config "$machine_dir" >/dev/null || true
  envmgr_refresh_summary "$(basename -- "$machine_dir")"
}

envmgr_cmd_restore() {
  local category=""
  local assume_yes=false
  local dry_run=false
  local machine_dir=""
  local provider=""
  local targets=()
  local rc=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes|-y) assume_yes=true ;;
      --dry-run|-n) dry_run=true ;;
      -*) envmgr_usage_error "unknown option for restore: $1" ;;
      *)
        if [[ -z "$category" && ${#targets[@]} -eq 0 ]]; then
          category="$(envmgr_parse_category "$1")"
        elif [[ "$category" == config ]]; then
          targets+=("$(envmgr_absolute_target "$1")")
        elif [[ "$category" == package && -z "$provider" ]]; then
          provider="$1"
        elif [[ "$category" == package ]]; then
          envmgr_usage_error "envmgr does not upgrade individual packages; see $ENVMGR_PARTIAL_UPGRADES_URL"
        else
          envmgr_usage_error "restore accepts target arguments only for config"
        fi
        ;;
    esac
    shift
  done

  machine_dir="$(envmgr_active_machine_dir refuse)"
  # Order: package -> config -> system. Only config is implemented so far.
  if [[ -z "$category" || "$category" == package ]]; then
    envmgr_warn "package restore is not implemented yet${provider:+ ($provider)}"
  fi
  if [[ -z "$category" || "$category" == config ]]; then
    envmgr_restore_config "$machine_dir" "$assume_yes" "$dry_run" \
      ${targets[@]+"${targets[@]}"} || rc=$?
    [[ "$dry_run" == true ]] || envmgr_refresh_config_check "$machine_dir"
  fi
  if [[ -z "$category" || "$category" == system ]]; then
    envmgr_warn "system restore is not implemented yet"
  fi
  return "$rc"
}

envmgr_cmd_adopt() {
  local category="${1:-}"
  local exact=false
  local encrypt=false
  local machine_dir=""
  local targets=()

  [[ $# -gt 0 ]] && shift
  case "$category" in
    config) ;;
    package) envmgr_die 1 "adopting packages is not implemented yet" ;;
    *) envmgr_usage_error "adopt requires a category: config or package" ;;
  esac
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --exact) exact=true ;;
      --encrypt) encrypt=true ;;
      -*) envmgr_usage_error "unknown option for adopt config: $1" ;;
      *) targets+=("$(envmgr_absolute_target "$1")") ;;
    esac
    shift
  done
  ((${#targets[@]})) || envmgr_usage_error "adopt config requires at least one target"

  machine_dir="$(envmgr_active_machine_dir refuse)"
  envmgr_adopt_config "$machine_dir" "$exact" "$encrypt" "${targets[@]}"
  envmgr_refresh_config_check "$machine_dir"
}

envmgr_cmd_drop() {
  local category="${1:-}"
  local delete=false
  local assume_yes=false
  local dry_run=false
  local machine_dir=""
  local targets=()
  local rc=0

  [[ $# -gt 0 ]] && shift
  case "$category" in
    config) ;;
    package) envmgr_die 1 "dropping packages is not implemented yet" ;;
    *) envmgr_usage_error "drop requires a category: config or package" ;;
  esac
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --delete) delete=true ;;
      --yes|-y) assume_yes=true ;;
      --dry-run|-n) dry_run=true ;;
      -*) envmgr_usage_error "unknown option for drop config: $1" ;;
      *) targets+=("$(envmgr_absolute_target "$1")") ;;
    esac
    shift
  done
  ((${#targets[@]})) || envmgr_usage_error "drop config requires at least one target"

  machine_dir="$(envmgr_active_machine_dir refuse)"
  envmgr_drop_config "$machine_dir" "$delete" "$assume_yes" "$dry_run" "${targets[@]}" || rc=$?
  [[ "$dry_run" == true ]] || envmgr_refresh_config_check "$machine_dir"
  return "$rc"
}

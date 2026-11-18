#!/usr/bin/env bash
# Command implementations.

envmgr_parse_category() {
  case "${1:-}" in
    config|package|system) printf '%s\n' "$1" ;;
    *) envmgr_usage_error "unknown category: $1 (expected config, package, or system)" ;;
  esac
}

# diff and save cover only config, so like the other config commands they
# take "config" as an optional first argument. Returns 0 when $1 names it;
# another category is a usage error.
envmgr_config_category_arg() {
  case "$1" in
    config) return 0 ;;
    package|system) envmgr_usage_error "$2 applies only to config" ;;
  esac
  return 1
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
  # Clear Chezmoi's record of a previous source's config template (for
  # example, the legacy .chezmoi.toml.tmpl), which otherwise warns on every
  # command. Without a template, init leaves chezmoi.toml unchanged.
  mkdir -p -- "$machine_dir/config"
  envmgr_chezmoi "$machine_dir" init >/dev/null
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
    for item in config packages system SPEC.md POSTINSTALL.md; do
      [[ -e "$from_dir/$item" ]] && cp -pR -- "$from_dir/$item" "$machine_dir/"
    done
    printf 'Created machine %s from %s.\n' "$machine" "$from"
  else
    printf '# %s\n\nDescribe this machine and its intended configuration.\n' \
      "$machine" >"$machine_dir/SPEC.md"
    printf 'Created empty machine %s.\n' "$machine"
  fi
  mkdir -p -- "$machine_dir/config" "$machine_dir/packages" "$machine_dir/system"
  # Every machine keeps the tool and its data current.
  if [[ -z "$from" ]]; then
    for item in "$ENVMGR_ROOT" "$data"; do
      (envmgr_adopt_package "$machine_dir" git "$item") || \
        envmgr_warn "declare $item with envmgr adopt package git"
    done
  fi
}

envmgr_cmd_check() {
  local category=""
  local offline=false
  local machine_dir=""
  local machine=""
  local provider=""
  local each=""
  local result=0
  local rc=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --offline) offline=true ;;
      -*) envmgr_usage_error "unknown option for check: $1" ;;
      *)
        if [[ -z "$category" ]]; then
          category="$(envmgr_parse_category "$1")"
        elif [[ "$category" == package && -z "$provider" ]]; then
          provider="$1"
        else
          envmgr_usage_error "unexpected argument for check: $1"
        fi
        ;;
    esac
    shift
  done

  machine_dir="$(envmgr_active_machine_dir warn)"
  machine="$(basename -- "$machine_dir")"

  # Every check refreshes every implemented category, so the marker reflects
  # the whole machine; only the requested category is printed.
  # Unrequested package checks run offline to stay fast.
  for each in package config system; do
    rc=0
    if [[ -z "$category" || "$category" == "$each" ]]; then
      if [[ "$each" == package ]]; then
        envmgr_check_package "$machine_dir" "$offline" "$provider" || rc=$?
      else
        "envmgr_check_$each" "$machine_dir" || rc=$?
      fi
    else
      if [[ "$each" == package ]]; then
        envmgr_check_package "$machine_dir" true >/dev/null 2>&1 || rc=$?
      else
        "envmgr_check_$each" "$machine_dir" >/dev/null 2>&1 || rc=$?
      fi
      continue
    fi
    case "$rc" in
      0) ;;
      "$ENVMGR_EXIT_DRIFT") [[ "$result" -ne 0 ]] || result="$ENVMGR_EXIT_DRIFT" ;;
      *) result=1 ;;
    esac
  done
  envmgr_refresh_summary "$machine"
  return "$result"
}

envmgr_cmd_list() {
  local category=""
  local machine_dir=""

  local provider=""

  if [[ $# -ge 1 ]]; then
    category="$(envmgr_parse_category "$1")"
  fi
  if [[ $# -eq 2 && "$category" == package ]]; then
    provider="$2"
  elif [[ $# -gt 1 ]]; then
    envmgr_usage_error "list takes a category, and a provider for package"
  fi
  machine_dir="$(envmgr_active_machine_dir warn)"

  if [[ -z "$category" || "$category" == package ]]; then
    [[ -z "$category" ]] && printf '# package\n'
    envmgr_list_package "$machine_dir" "$provider"
  fi

  if [[ -z "$category" || "$category" == config ]]; then
    [[ -z "$category" ]] && printf '# config\n'
    envmgr_list_config "$machine_dir"
  fi
  if [[ -z "$category" || "$category" == system ]]; then
    [[ -z "$category" ]] && printf '# system\n'
    envmgr_list_system "$machine_dir"
  fi
}

# Refresh recorded results and the marker after a command changed state.
envmgr_refresh_checks() {
  local machine_dir="$1"

  envmgr_check_package "$machine_dir" true >/dev/null 2>&1 || true
  envmgr_check_config "$machine_dir" >/dev/null 2>&1 || true
  envmgr_check_system "$machine_dir" >/dev/null 2>&1 || true
  envmgr_refresh_summary "$(basename -- "$machine_dir")"
}

envmgr_cmd_restore() {
  local category=""
  local assume_yes=false
  local dry_run=false
  local force=false
  local machine_dir=""
  local provider=""
  local targets=()
  local units=()
  local rc=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes|-y) assume_yes=true ;;
      --dry-run|-n) dry_run=true ;;
      --force) force=true ;;
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
          units+=("$1")
        fi
        ;;
    esac
    shift
  done

  [[ "$force" == false || "$category" == system ]] || \
    envmgr_usage_error "--force applies only to restore system"

  machine_dir="$(envmgr_active_machine_dir refuse)"
  # Order: package -> config -> system. A phase that fails, is cancelled, or
  # needs a reboot stops the run.
  if [[ -z "$category" || "$category" == package ]]; then
    envmgr_restore_package "$machine_dir" "$assume_yes" "$dry_run" "$provider" || rc=$?
  fi
  if [[ "$rc" -eq 0 && ( -z "$category" || "$category" == config ) ]]; then
    envmgr_restore_config "$machine_dir" "$assume_yes" "$dry_run" \
      ${targets[@]+"${targets[@]}"} || rc=$?
  fi
  if [[ "$rc" -eq 0 && ( -z "$category" || "$category" == system ) ]]; then
    envmgr_restore_system "$machine_dir" "$assume_yes" "$dry_run" "$force" \
      ${units[@]+"${units[@]}"} || rc=$?
  fi
  [[ "$dry_run" == true ]] || envmgr_refresh_checks "$machine_dir"
  return "$rc"
}

envmgr_cmd_adopt() {
  local category="${1:-}"
  local exact=false
  local encrypt=false
  local from=""
  local machine_dir=""
  local from_dir=""
  local targets=()

  [[ $# -gt 0 ]] && shift
  case "$category" in
    config) ;;
    package)
      [[ $# -ge 2 ]] || envmgr_usage_error "adopt package requires a provider and at least one package"
      machine_dir="$(envmgr_active_machine_dir refuse)"
      envmgr_adopt_package "$machine_dir" "$@"
      envmgr_refresh_checks "$machine_dir"
      return 0
      ;;
    *) envmgr_usage_error "adopt requires a category: config or package" ;;
  esac
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --exact) exact=true ;;
      --encrypt) encrypt=true ;;
      --from)
        [[ $# -ge 2 && -n "$2" ]] || envmgr_usage_error "--from requires a machine ID"
        envmgr_valid_machine_id "$2" || envmgr_usage_error "invalid machine ID: $2"
        from="$2"
        shift
        ;;
      -*) envmgr_usage_error "unknown option for adopt config: $1" ;;
      *) targets+=("$(envmgr_absolute_target "$1")") ;;
    esac
    shift
  done
  ((${#targets[@]})) || envmgr_usage_error "adopt config requires at least one target"
  [[ -z "$from" || ( "$exact" == false && "$encrypt" == false ) ]] || \
    envmgr_usage_error "--from copies sources as they are; it cannot be combined with --exact or --encrypt"

  machine_dir="$(envmgr_active_machine_dir refuse)"
  if [[ -n "$from" ]]; then
    [[ "$from" != "$(basename -- "$machine_dir")" ]] || \
      envmgr_usage_error "--from names the selected machine; give another machine ID"
    from_dir="$(dirname -- "$machine_dir")/$from"
    [[ -d "$from_dir" ]] || envmgr_die 1 "machine does not exist: $from"
    envmgr_adopt_config_from "$machine_dir" "$from_dir" "${targets[@]}"
  else
    envmgr_adopt_config "$machine_dir" "$exact" "$encrypt" "${targets[@]}"
  fi
  envmgr_refresh_checks "$machine_dir"
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
    package)
      envmgr_cmd_drop_package "$@"
      return
      ;;
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
  [[ "$dry_run" == true ]] || envmgr_refresh_checks "$machine_dir"
  return "$rc"
}

envmgr_cmd_diff() {
  local category=false
  local machine_dir=""
  local targets=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -*) envmgr_usage_error "unknown option for diff: $1" ;;
      *)
        if [[ "$category" == false && ${#targets[@]} -eq 0 ]] && \
          envmgr_config_category_arg "$1" diff; then
          category=true
        else
          targets+=("$(envmgr_absolute_target "$1")")
        fi
        ;;
    esac
    shift
  done

  machine_dir="$(envmgr_active_machine_dir warn)"
  envmgr_diff_config "$machine_dir" ${targets[@]+"${targets[@]}"}
}

envmgr_cmd_save() {
  local assume_yes=false
  local dry_run=false
  local force=false
  local category=false
  local machine_dir=""
  local targets=()
  local rc=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes|-y) assume_yes=true ;;
      --dry-run|-n) dry_run=true ;;
      --force) force=true ;;
      -*) envmgr_usage_error "unknown option for save: $1" ;;
      *)
        if [[ "$category" == false && ${#targets[@]} -eq 0 ]] && \
          envmgr_config_category_arg "$1" save; then
          category=true
        else
          targets+=("$(envmgr_absolute_target "$1")")
        fi
        ;;
    esac
    shift
  done
  [[ "$force" == false || ${#targets[@]} -gt 0 ]] || \
    envmgr_usage_error "save --force overwrites source changes, so it needs the targets named"

  machine_dir="$(envmgr_active_machine_dir refuse)"
  envmgr_save_config "$machine_dir" "$assume_yes" "$dry_run" "$force" ${targets[@]+"${targets[@]}"} || rc=$?
  [[ "$dry_run" == true ]] || envmgr_refresh_checks "$machine_dir"
  return "$rc"
}

envmgr_cmd_drop_package() {
  local delete=false
  local assume_yes=false
  local dry_run=false
  local provider=""
  local machine_dir=""
  local packages=()
  local rc=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --delete) delete=true ;;
      --yes|-y) assume_yes=true ;;
      --dry-run|-n) dry_run=true ;;
      -*) envmgr_usage_error "unknown option for drop package: $1" ;;
      *)
        if [[ -z "$provider" ]]; then
          provider="$1"
        else
          packages+=("$1")
        fi
        ;;
    esac
    shift
  done
  [[ -n "$provider" && ${#packages[@]} -gt 0 ]] || \
    envmgr_usage_error "drop package requires a provider and at least one package"
  envmgr_known_provider "$provider" || envmgr_usage_error "unknown provider: $provider"

  machine_dir="$(envmgr_active_machine_dir refuse)"
  envmgr_drop_package "$machine_dir" "$provider" "$delete" "$assume_yes" "$dry_run" \
    "${packages[@]}" || rc=$?
  [[ "$dry_run" == true ]] || envmgr_refresh_checks "$machine_dir"
  return "$rc"
}

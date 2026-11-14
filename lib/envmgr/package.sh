#!/usr/bin/env bash
# Package category: provider framework. Each provider lives in
# lib/envmgr/providers/<name>.sh and defines envmgr_pkg_<id>_<operation>,
# where <id> is the provider name with "-" replaced by "_":
#
#   available        exit 0 when the package manager can be used
#   bootstrap        install the package manager; may exit 75
#   refresh          refresh metadata without changing installed state
#   list             print declared packages, one per line ("name" or "name held")
#   missing          print declared packages that are not installed
#   pending          print one line per pending upgrade, or nothing
#   restore          install missing packages and upgrade; may exit 75
#   adopt <pkg...>   record installed packages in the manifest
#   forget <pkg...>  remove packages from the manifest
#   uninstall <pkg...>

ENVMGR_PROVIDERS="git rpm-ostree omarchy homebrew flatpak"

envmgr_provider_id() {
  printf '%s\n' "${1//-/_}"
}

envmgr_known_provider() {
  case " $ENVMGR_PROVIDERS " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

# Call a provider operation with the manifest directory exported.
envmgr_pkg_call() {
  local provider="$1"
  local operation="$2"
  local function=""

  shift 2
  function="envmgr_pkg_$(envmgr_provider_id "$provider")_$operation"
  declare -F "$function" >/dev/null || \
    envmgr_die 1 "provider $provider does not support $operation"
  "$function" "$@"
}

# Print the machine's active providers in run order, optionally limited to one.
envmgr_active_providers() {
  local machine_dir="$1"
  local selected="${2:-}"
  local dir=""
  local name=""
  local provider=""

  if [[ -n "$selected" ]]; then
    envmgr_known_provider "$selected" || envmgr_usage_error "unknown provider: $selected"
    [[ -d "$machine_dir/packages/$selected" ]] || \
      envmgr_die 1 "this machine does not use provider $selected"
  fi
  if [[ -d "$machine_dir/packages" ]]; then
    for dir in "$machine_dir"/packages/*/; do
      [[ -d "$dir" ]] || continue
      name="$(basename -- "$dir")"
      envmgr_known_provider "$name" || \
        envmgr_die 1 "unknown provider directory: $machine_dir/packages/$name"
    done
  fi
  for provider in $ENVMGR_PROVIDERS; do
    [[ -d "$machine_dir/packages/$provider" ]] || continue
    [[ -z "$selected" || "$selected" == "$provider" ]] || continue
    printf '%s\n' "$provider"
  done
}

envmgr_load_providers() {
  local provider=""

  for provider in $ENVMGR_PROVIDERS; do
    # shellcheck source=/dev/null
    source "$ENVMGR_ROOT/lib/envmgr/providers/$provider.sh"
  done
}

# Prepare the provider environment for one machine and provider.
envmgr_pkg_enter() {
  local machine_dir="$1"
  local provider="$2"

  ENVMGR_MANIFEST_DIR="$machine_dir/packages/$provider"
  export ENVMGR_MANIFEST_DIR
}

envmgr_count_lines() {
  if [[ -z "$1" ]]; then
    printf '0\n'
  else
    printf '%s\n' "$1" | grep -c .
  fi
}

envmgr_check_package() {
  local machine_dir="$1"
  local offline="$2"
  local selected="${3:-}"
  local provider=""
  local providers=""
  local missing=""
  local pending=""
  local missing_total=0
  local pending_providers=""
  local errors=0
  local line=""

  providers="$(envmgr_active_providers "$machine_dir" "$selected")" || return 1
  for provider in $providers; do
    envmgr_pkg_enter "$machine_dir" "$provider"
    if ! envmgr_pkg_call "$provider" available; then
      missing="$(envmgr_pkg_call "$provider" list | awk '{ print $1 }')"
      pending=""
      printf 'package/%s: not installed; %d declared package(s) missing\n' \
        "$provider" "$(envmgr_count_lines "$missing")"
    else
      if [[ "$offline" != true ]] && ! envmgr_pkg_call "$provider" refresh; then
        envmgr_warn "$provider: metadata refresh failed; using cached metadata"
      fi
      if ! missing="$(envmgr_pkg_call "$provider" missing)" || \
        ! pending="$(envmgr_pkg_call "$provider" pending)"; then
        printf 'package/%s: error\n' "$provider"
        errors=$((errors + 1))
        continue
      fi
      if [[ -z "$missing" && -z "$pending" ]]; then
        printf 'package/%s: in sync\n' "$provider"
      else
        printf 'package/%s: %d missing, %d pending\n' "$provider" \
          "$(envmgr_count_lines "$missing")" "$(envmgr_count_lines "$pending")"
      fi
    fi
    while IFS= read -r line; do
      [[ -n "$line" ]] && printf '  missing  %s\n' "$line"
    done <<<"$missing"
    while IFS= read -r line; do
      [[ -n "$line" ]] && printf '  pending  %s\n' "$line"
    done <<<"$pending"
    missing_total=$((missing_total + $(envmgr_count_lines "$missing")))
    if [[ -n "$pending" ]]; then
      pending_providers="${pending_providers:+$pending_providers,}$provider"
    fi
  done
  [[ -n "$providers" ]] || printf 'package: no providers\n'

  envmgr_record_result package "package.missing=$missing_total" \
    "package.pending=$pending_providers" "package.errors=$errors"
  ((errors == 0)) || return 1
  [[ "$missing_total" -eq 0 && -z "$pending_providers" ]] || return "$ENVMGR_EXIT_DRIFT"
}

envmgr_list_package() {
  local machine_dir="$1"
  local selected="${2:-}"
  local provider=""
  local name=""
  local flag=""

  local providers=""

  providers="$(envmgr_active_providers "$machine_dir" "$selected")" || return 1
  for provider in $providers; do
    envmgr_pkg_enter "$machine_dir" "$provider"
    while read -r name flag; do
      [[ -n "$name" ]] && printf '%-11s %s%s\n' "$provider" "$name" "${flag:+  ($flag)}"
    done < <(envmgr_pkg_call "$provider" list)
  done
}

envmgr_git_head() {
  git -C "$1" rev-parse HEAD 2>/dev/null || true
}

envmgr_restore_package() {
  local machine_dir="$1"
  local assume_yes="$2"
  local dry_run="$3"
  local selected="${4:-}"
  local provider=""
  local providers=""
  local missing=""
  local pending=""
  local work=()
  local rc=0
  local data_dir=""
  local tool_head=""
  local data_head=""

  providers="$(envmgr_active_providers "$machine_dir" "$selected")" || return 1
  for provider in $providers; do
    envmgr_pkg_enter "$machine_dir" "$provider"
    if ! envmgr_pkg_call "$provider" available; then
      printf 'package/%s: install the package manager, then its declared packages\n' "$provider"
      work+=("$provider")
      continue
    fi
    envmgr_pkg_call "$provider" refresh || \
      envmgr_warn "$provider: metadata refresh failed; using cached metadata"
    missing="$(envmgr_pkg_call "$provider" missing)" || return 1
    pending="$(envmgr_pkg_call "$provider" pending)" || return 1
    [[ -n "$missing" || -n "$pending" ]] || continue
    printf 'package/%s:\n' "$provider"
    printf '%s\n' "$missing" | awk 'NF { print "  install  " $0 }'
    printf '%s\n' "$pending" | awk 'NF { print "  upgrade  " $0 }'
    work+=("$provider")
  done

  if ((${#work[@]} == 0)); then
    printf 'package: nothing to restore\n'
    return 0
  fi
  [[ "$dry_run" == true ]] && return 0
  envmgr_confirm "Restore packages for ${work[*]}?" "$assume_yes" || {
    printf 'package: restore cancelled\n'
    return 1
  }

  data_dir="$(dirname -- "$(dirname -- "$machine_dir")")"
  ENVMGR_ASSUME_YES="$assume_yes"
  export ENVMGR_ASSUME_YES
  for provider in "${work[@]}"; do
    envmgr_pkg_enter "$machine_dir" "$provider"
    rc=0
    if ! envmgr_pkg_call "$provider" available; then
      printf 'package/%s: installing the package manager\n' "$provider"
      envmgr_pkg_call "$provider" bootstrap || rc=$?
    fi
    if [[ "$provider" == git ]]; then
      tool_head="$(envmgr_git_head "$ENVMGR_ROOT")"
      data_head="$(envmgr_git_head "$data_dir")"
    fi
    [[ "$rc" -ne 0 ]] || envmgr_pkg_call "$provider" restore || rc=$?
    case "$rc" in
      0) ;;
      "$ENVMGR_EXIT_REBOOT")
        printf 'package/%s: reboot required; rerun envmgr restore afterward\n' "$provider"
        return "$ENVMGR_EXIT_REBOOT"
        ;;
      *)
        printf 'envmgr: error: package restore failed for %s\n' "$provider" >&2
        return 1
        ;;
    esac
    # A pulled tool or data checkout changes the code and manifests for the
    # rest of the run: re-execute once with the original arguments.
    if [[ "$provider" == git && -z "${ENVMGR_REEXECUTED:-}" ]] && \
      { [[ "$(envmgr_git_head "$ENVMGR_ROOT")" != "$tool_head" ]] || \
        [[ "$(envmgr_git_head "$data_dir")" != "$data_head" ]]; }; then
      printf 'package/git: envmgr or its data changed; restarting restore\n'
      export ENVMGR_REEXECUTED=1
      exec "$ENVMGR_ROOT/bin/envmgr" ${ENVMGR_ARGS[@]+"${ENVMGR_ARGS[@]}"}
    fi
  done
  printf 'package: restored %s\n' "${work[*]}"
}

envmgr_adopt_package() {
  local machine_dir="$1"
  local provider="$2"

  shift 2
  envmgr_known_provider "$provider" || envmgr_usage_error "unknown provider: $provider"
  mkdir -p -- "$machine_dir/packages/$provider"
  envmgr_pkg_enter "$machine_dir" "$provider"
  envmgr_pkg_call "$provider" available || envmgr_die 1 "$provider is not installed"
  envmgr_pkg_call "$provider" adopt "$@"
}

envmgr_drop_package() {
  local machine_dir="$1"
  local provider="$2"
  local delete="$3"
  local assume_yes="$4"
  local dry_run="$5"

  shift 5
  [[ -d "$machine_dir/packages/$provider" ]] || \
    envmgr_die 1 "this machine does not use provider $provider"
  envmgr_pkg_enter "$machine_dir" "$provider"
  if [[ "$delete" == true ]]; then
    printf 'package/%s: will stop managing and uninstall: %s\n' "$provider" "$*"
  else
    printf 'package/%s: will stop managing (left installed): %s\n' "$provider" "$*"
  fi
  [[ "$dry_run" == true ]] && return 0
  if [[ "$delete" == true ]]; then
    envmgr_confirm "Uninstall these packages?" "$assume_yes" || {
      printf 'package: drop cancelled\n'
      return 1
    }
  fi
  if [[ "$delete" == true ]] && ! envmgr_pkg_call "$provider" available; then
    envmgr_die 1 "$provider is not installed"
  fi
  envmgr_pkg_call "$provider" forget "$@" || return 1
  if [[ "$delete" == true ]]; then
    envmgr_pkg_call "$provider" uninstall "$@" || return 1
  fi
}

# Remove exact lines (after trimming) matching any of the given patterns'
# package field from a manifest. Usage: envmgr_manifest_remove file awk-key pkg...
envmgr_manifest_filter() {
  local file="$1"
  local program="$2"
  local tmp=""

  shift 2
  [[ -f "$file" ]] || return 0
  tmp="$(mktemp "$file.XXXXXX")"
  awk -v names="$*" "$program" "$file" >"$tmp"
  mv -f -- "$tmp" "$file"
}

#!/usr/bin/env bash
# System category: machine-owned units with apply and optional check scripts.

envmgr_system_units() {
  local machine_dir="$1"
  local unit=""

  [[ -d "$machine_dir/system" ]] || return 0
  for unit in "$machine_dir"/system/*/; do
    [[ -d "$unit" ]] && basename -- "$unit"
  done | LC_ALL=C sort
}

# Resolve a unit argument ("60-paneru" or "paneru") to its directory name.
envmgr_resolve_unit() {
  local machine_dir="$1"
  local name="$2"
  local unit=""

  while IFS= read -r unit; do
    if [[ "$unit" == "$name" || "${unit#[0-9][0-9]-}" == "$name" ]]; then
      printf '%s\n' "$unit"
      return 0
    fi
  done < <(envmgr_system_units "$machine_dir")
  envmgr_die 1 "unknown system unit: $name"
}

envmgr_unit_description() {
  local apply="$1"

  awk 'NR > 1 && /^#[^!]/ { sub(/^#[[:space:]]*/, ""); print; exit }' "$apply"
}

envmgr_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{ print $1 }'
  else
    shasum -a 256 | awk '{ print $1 }'
  fi
}

# Hash of the unit's files plus the current contents of its watched targets.
envmgr_unit_hash() {
  local unit_dir="$1"
  local file=""
  local pattern=""
  local path=""

  {
    while IFS= read -r file; do
      printf 'unit %s %s\n' "$file" "$(envmgr_sha256 <"$unit_dir/$file")"
    done < <(cd -- "$unit_dir" && find . -type f -print | LC_ALL=C sort)

    if [[ -f "$unit_dir/watch" ]]; then
      while IFS= read -r pattern; do
        [[ -n "$pattern" && "$pattern" != \#* ]] || continue
        pattern="$(envmgr_expand_path "$pattern")"
        # Unquoted on purpose: watch lines may contain globs.
        # shellcheck disable=SC2086
        for path in $pattern; do
          if [[ -f "$path" ]]; then
            printf 'watch %s %s\n' "$path" "$(envmgr_sha256 <"$path")"
          else
            printf 'watch %s missing\n' "$path"
          fi
        done
      done <"$unit_dir/watch"
    fi
  } | envmgr_sha256
}

envmgr_unit_stamp() {
  local machine="$1"
  local unit="$2"

  printf '%s\n' "$(envmgr_state_dir)/system/$machine/$unit.applied"
}

envmgr_run_unit_script() {
  local machine_dir="$1"
  local unit="$2"
  local script="$3"
  local unit_dir="$machine_dir/system/$unit"

  [[ -x "$unit_dir/$script" ]] || {
    printf 'envmgr: error: %s is not executable\n' "$unit_dir/$script" >&2
    return 1
  }
  (
    cd -- "$unit_dir"
    ENVMGR_UNIT_DIR="$unit_dir" \
      ENVMGR_MACHINE_DIR="$machine_dir" \
      ENVMGR_DATA_DIR="$(dirname -- "$(dirname -- "$machine_dir")")" \
      ENVMGR_MACHINE="$(basename -- "$machine_dir")" \
      "$unit_dir/$script"
  )
}

# Print one unit's state: in-sync, drift, or error. Returns 0, 3, or 1.
envmgr_check_unit() {
  local machine_dir="$1"
  local unit="$2"
  local unit_dir="$machine_dir/system/$unit"
  local stamp=""
  local rc=0

  if [[ ! -f "$unit_dir/apply" ]]; then
    printf 'envmgr: error: system unit %s has no apply script\n' "$unit" >&2
    return 1
  fi
  if [[ -e "$unit_dir/check" ]]; then
    envmgr_run_unit_script "$machine_dir" "$unit" check >/dev/null || rc=$?
    case "$rc" in
      0|"$ENVMGR_EXIT_DRIFT") return "$rc" ;;
      *) return 1 ;;
    esac
  fi

  stamp="$(envmgr_unit_stamp "$(basename -- "$machine_dir")" "$unit")"
  [[ -f "$stamp" && "$(cat -- "$stamp")" == "$(envmgr_unit_hash "$unit_dir")" ]] || \
    return "$ENVMGR_EXIT_DRIFT"
}

envmgr_check_system() {
  local machine_dir="$1"
  local unit=""
  local rc=0
  local drift=0
  local errors=0
  local details=()

  while IFS= read -r unit; do
    rc=0
    envmgr_check_unit "$machine_dir" "$unit" || rc=$?
    case "$rc" in
      0) ;;
      "$ENVMGR_EXIT_DRIFT")
        drift=$((drift + 1))
        details+=("  drift    $unit")
        ;;
      *)
        errors=$((errors + 1))
        details+=("  error    $unit")
        ;;
    esac
  done < <(envmgr_system_units "$machine_dir")

  envmgr_record_result system "system.drift=$drift" "system.errors=$errors"
  if ((drift == 0 && errors == 0)); then
    printf 'system: in sync\n'
    return 0
  fi
  printf 'system: %d unit(s) out of sync, %d error(s)\n' "$drift" "$errors"
  printf '%s\n' "${details[@]}"
  ((errors == 0)) || return 1
  return "$ENVMGR_EXIT_DRIFT"
}

envmgr_list_system() {
  local machine_dir="$1"
  local unit=""
  local kind=""

  while IFS= read -r unit; do
    kind=stamp
    [[ -e "$machine_dir/system/$unit/check" ]] && kind=check
    printf '%-24s %-5s  %s\n' "$unit" "$kind" \
      "$(envmgr_unit_description "$machine_dir/system/$unit/apply" 2>/dev/null)"
  done < <(envmgr_system_units "$machine_dir")
}

# Apply out-of-sync units (or all selected units with force), in order.
envmgr_restore_system() {
  local machine_dir="$1"
  local assume_yes="$2"
  local dry_run="$3"
  local force="$4"
  local machine=""
  local unit=""
  local stamp=""
  local rc=0
  local selected=()
  local pending=()

  shift 4
  machine="$(basename -- "$machine_dir")"
  if [[ $# -gt 0 ]]; then
    for unit in "$@"; do
      selected+=("$(envmgr_resolve_unit "$machine_dir" "$unit")")
    done
  else
    while IFS= read -r unit; do
      selected+=("$unit")
    done < <(envmgr_system_units "$machine_dir")
  fi

  for unit in ${selected[@]+"${selected[@]}"}; do
    rc=0
    [[ "$force" == true ]] || envmgr_check_unit "$machine_dir" "$unit" || rc=$?
    case "$rc" in
      0) [[ "$force" == true ]] && pending+=("$unit") ;;
      "$ENVMGR_EXIT_DRIFT") pending+=("$unit") ;;
      *)
        printf 'envmgr: error: cannot check system unit %s\n' "$unit" >&2
        return 1
        ;;
    esac
  done

  if ((${#pending[@]} == 0)); then
    printf 'system: nothing to restore\n'
    return 0
  fi
  printf 'system: will apply:\n'
  for unit in "${pending[@]}"; do
    printf '  %-24s %s\n' "$unit" "$(envmgr_unit_description "$machine_dir/system/$unit/apply")"
  done
  [[ "$dry_run" == true ]] && return 0
  envmgr_confirm "Apply ${#pending[@]} system unit(s)?" "$assume_yes" || {
    printf 'system: restore cancelled\n'
    return 1
  }

  for unit in "${pending[@]}"; do
    printf 'system: applying %s\n' "$unit"
    rc=0
    envmgr_run_unit_script "$machine_dir" "$unit" apply || rc=$?
    case "$rc" in
      0)
        stamp="$(envmgr_unit_stamp "$machine" "$unit")"
        mkdir -p -- "$(dirname -- "$stamp")"
        envmgr_unit_hash "$machine_dir/system/$unit" >"$stamp"
        ;;
      "$ENVMGR_EXIT_REBOOT")
        printf 'system: %s requires a reboot or re-login; rerun envmgr restore afterward\n' "$unit"
        return "$ENVMGR_EXIT_REBOOT"
        ;;
      *)
        printf 'envmgr: error: system unit %s failed (exit %d)\n' "$unit" "$rc" >&2
        return 1
        ;;
    esac
  done
  printf 'system: applied %d unit(s)\n' "${#pending[@]}"
}

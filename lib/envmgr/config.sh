#!/usr/bin/env bash
# Configuration category, backed by Chezmoi.

envmgr_chezmoi() {
  local machine_dir="$1"

  shift
  command -v chezmoi >/dev/null 2>&1 || \
    envmgr_die 1 "chezmoi is not installed; run 'envmgr setup'"
  chezmoi --source "$machine_dir/config" "$@"
}

# Write chezmoi.toml so plain chezmoi commands use the selected machine.
envmgr_write_chezmoi_config() {
  local machine_dir="$1"
  local file=""
  local desired=""

  file="$(envmgr_config_home)/chezmoi/chezmoi.toml"
  desired="$(printf '# Managed by envmgr; changed by envmgr init.\nsourceDir = "%s"\n' "$machine_dir/config")"
  if [[ -f "$file" && "$(cat -- "$file")" == "$desired" ]]; then
    return 0
  fi
  envmgr_backup_file "$file" chezmoi
  mkdir -p -- "$(dirname -- "$file")"
  printf '%s\n' "$desired" >"$file"
}

# Print Chezmoi status lines for config targets ("XY path").
envmgr_config_status() {
  local machine_dir="$1"

  [[ -d "$machine_dir/config" ]] || return 0
  envmgr_chezmoi "$machine_dir" status --exclude scripts
}

# Report config drift and record it. Returns 0 in sync, 3 on drift.
envmgr_check_config() {
  local machine_dir="$1"
  local status=""
  local line=""
  local local_count=0
  local pending_count=0
  local details=()

  # Callers use "|| rc=$?", which disables set -e here; fail explicitly.
  status="$(envmgr_config_status "$machine_dir")" || return 1
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    # Column one: last written state versus the actual target.
    if [[ "${line:0:1}" != " " ]]; then
      local_count=$((local_count + 1))
      details+=("  local    ${line:3}")
    fi
    # Column two: actual target versus the machine's source.
    if [[ "${line:1:1}" != " " ]]; then
      pending_count=$((pending_count + 1))
      details+=("  pending  ${line:3}")
    fi
  done <<<"$status"

  envmgr_record_result config "config.local=$local_count" "config.pending=$pending_count"
  if ((local_count == 0 && pending_count == 0)); then
    printf 'config: in sync\n'
    return 0
  fi
  printf 'config: %d local change(s), %d pending restore\n' "$local_count" "$pending_count"
  printf '%s\n' "${details[@]}"
  return "$ENVMGR_EXIT_DRIFT"
}

envmgr_list_config() {
  local machine_dir="$1"
  local target=""
  local source=""
  local kind=""
  local files=()
  local sources=()
  local i=0

  [[ -d "$machine_dir/config" ]] || return 0

  while IFS= read -r target; do
    [[ -n "$target" ]] && printf 'directory  %s\n' "$target"
  done < <(envmgr_chezmoi "$machine_dir" managed --include dirs)

  while IFS= read -r target; do
    [[ -n "$target" ]] && files+=("$target")
  done < <(envmgr_chezmoi "$machine_dir" managed --include files,symlinks --path-style absolute)
  ((${#files[@]})) || return 0

  while IFS= read -r source; do
    sources+=("$source")
  done < <(envmgr_chezmoi "$machine_dir" source-path "${files[@]}")

  for ((i = 0; i < ${#files[@]}; i++)); do
    source="$(basename -- "${sources[$i]:-}")"
    case "$source" in
      modify_*) kind=modify ;;
      encrypted_*) kind=encrypted ;;
      symlink_*) kind=symlink ;;
      *) kind=file ;;
    esac
    printf '%-9s  %s\n' "$kind" "${files[$i]#"$HOME"/}"
  done
}

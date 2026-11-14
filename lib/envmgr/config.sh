#!/usr/bin/env bash
# Configuration category, backed by Chezmoi.

envmgr_chezmoi() {
  local machine_dir="$1"

  shift
  command -v chezmoi >/dev/null 2>&1 || \
    envmgr_die 1 "chezmoi is not installed; run 'envmgr setup'"
  chezmoi --source "$machine_dir/config" "$@"
}

envmgr_age_key_file() {
  printf '%s\n' "$(envmgr_config_home)/envmgr/age.key"
}

# Print the age recipient (public key) for an identity file.
envmgr_age_recipient() {
  local key="$1"
  local recipient=""

  recipient="$(sed -n 's/^# public key: //p' "$key" | head -n 1)"
  [[ -n "$recipient" ]] || recipient="$(chezmoi age-keygen --convert "$key")" || return 1
  printf '%s\n' "$recipient"
}

envmgr_chezmoi_config_text() {
  local machine_dir="$1"
  local key=""

  key="$(envmgr_age_key_file)"
  printf '# Managed by envmgr; changed by envmgr init.\n'
  printf 'sourceDir = "%s"\n' "$machine_dir/config"
  # Set even without a key: Chezmoi then still maps encrypted_ sources to
  # their targets, so they can be listed and dropped after a key is lost.
  printf 'encryption = "age"\n'
  [[ -r "$key" ]] || return 0
  printf '\n[age]\n'
  printf '  identity = "%s"\n' "$key"
  printf '  recipient = "%s"\n' "$(envmgr_age_recipient "$key")"
}

# Write chezmoi.toml so plain chezmoi commands use the selected machine.
envmgr_write_chezmoi_config() {
  local machine_dir="$1"
  local file=""
  local desired=""

  file="$(envmgr_config_home)/chezmoi/chezmoi.toml"
  desired="$(envmgr_chezmoi_config_text "$machine_dir")" || return 1
  if [[ -f "$file" && "$(cat -- "$file")" == "$desired" ]]; then
    return 0
  fi
  envmgr_backup_file "$file" chezmoi
  mkdir -p -- "$(dirname -- "$file")"
  printf '%s\n' "$desired" >"$file"
}

# Before Chezmoi reads encrypted sources: add the age settings to an
# envmgr-managed chezmoi.toml once a key exists (for example, after it was
# copied from another machine), and explain a missing key.
envmgr_config_prepare() {
  local machine_dir="$1"
  local file=""
  local desired=""

  file="$(envmgr_config_home)/chezmoi/chezmoi.toml"
  if [[ -f "$file" ]] && \
    grep -Fxq "sourceDir = \"$machine_dir/config\"" "$file" && \
    [[ "$(head -n 1 -- "$file")" == "# Managed by envmgr"* ]]; then
    desired="$(envmgr_chezmoi_config_text "$machine_dir")" || return 1
    [[ "$(cat -- "$file")" == "$desired" ]] || printf '%s\n' "$desired" >"$file"
  fi

  if [[ ! -r "$(envmgr_age_key_file)" && -d "$machine_dir/config" ]] && \
    [[ -n "$(find "$machine_dir/config" -name 'encrypted_*' -print | head -n 1)" ]]; then
    envmgr_die 1 "machine $(basename -- "$machine_dir") has encrypted files, but the age key is missing; copy $(envmgr_display_path "$(envmgr_age_key_file)") from a machine that has it"
  fi
}

# Create the age identity that encrypts adopted secrets. It never leaves
# this machine except by the user copying it.
envmgr_create_age_key() {
  local key=""

  key="$(envmgr_age_key_file)"
  [[ -e "$key" ]] && return 0
  mkdir -p -- "$(dirname -- "$key")"
  (umask 077 && chezmoi age-keygen --output "$key" >/dev/null 2>&1) || \
    envmgr_die 1 "could not create the age key $key"
  chmod 600 "$key"
  printf 'Created the age key %s.\n' "$(envmgr_display_path "$key")"
  printf 'Back it up (for example, in a password manager) and copy it to every\n'
  printf 'machine that restores encrypted files. Envmgr never commits it, and\n'
  printf 'encrypted files cannot be restored without it.\n'
}

# Print Chezmoi status lines for config targets ("XY path").
envmgr_config_status() {
  local machine_dir="$1"

  [[ -d "$machine_dir/config" ]] || return 0
  envmgr_config_prepare "$machine_dir" || return 1
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

# Print the source path for each managed target, one per line, in order.
envmgr_config_source_paths() {
  local machine_dir="$1"

  shift
  envmgr_chezmoi "$machine_dir" source-path "$@"
}

envmgr_config_is_managed() {
  local machine_dir="$1"
  local target="$2"

  envmgr_chezmoi "$machine_dir" source-path "$target" >/dev/null 2>&1
}

# Copy existing target files that restore is about to change. Files inside
# exact_ directories are owned outright by the machine and are not backed up.
envmgr_backup_targets() {
  local machine_dir="$1"
  local status="$2"
  local line=""
  local relative=""
  local source=""
  local backup_root=""

  backup_root="$(envmgr_state_dir)/backups/$(envmgr_timestamp)"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    relative="${line:3}"
    [[ -f "$HOME/$relative" && ! -L "$HOME/$relative" ]] || continue
    # Targets with no source are being removed from an exact_ directory.
    source="$(envmgr_config_source_paths "$machine_dir" "$HOME/$relative" 2>/dev/null)" || continue
    case "${source#"$machine_dir/config"}" in
      */exact_*) continue ;;
    esac
    mkdir -p -- "$backup_root/$(dirname -- "$relative")"
    cp -p -- "$HOME/$relative" "$backup_root/$relative"
    printf 'Backed up ~/%s\n' "$relative"
  done <<<"$status"
}

envmgr_restore_config() {
  local machine_dir="$1"
  local assume_yes="$2"
  local dry_run="$3"
  local status=""
  local count=0

  shift 3
  if [[ ! -d "$machine_dir/config" ]]; then
    printf 'config: nothing to restore\n'
    return 0
  fi
  envmgr_config_prepare "$machine_dir" || return 1
  status="$(envmgr_chezmoi "$machine_dir" status --exclude scripts "$@")" || return 1
  [[ -n "$status" ]] && count="$(printf '%s\n' "$status" | grep -c .)"
  if ((count == 0)); then
    printf 'config: nothing to restore\n'
    return 0
  fi

  printf 'config: %d target(s) will change\n' "$count"
  envmgr_chezmoi "$machine_dir" diff --no-pager --exclude scripts "$@" || return 1
  [[ "$dry_run" == true ]] && return 0
  envmgr_confirm "Restore $count config target(s)?" "$assume_yes" || {
    printf 'config: restore cancelled\n'
    return 1
  }

  envmgr_backup_targets "$machine_dir" "$status" || return 1
  envmgr_chezmoi "$machine_dir" apply --force --exclude scripts "$@" || return 1
  printf 'config: restored %d target(s)\n' "$count"
}

# File names that must be encrypted to adopt. Returns 1 for *.pub, which is
# never a secret, and 2 when the name alone does not decide.
envmgr_looks_secret_name() {
  case "$1" in
    *.pub) return 1 ;;
    id_rsa*|id_dsa*|id_ecdsa*|id_ed25519*|*.pem|*.key|*.p12|*.pfx) return 0 ;;
    .netrc|.pgpass|credentials|credentials.*|*token*|*secret*) return 0 ;;
  esac
  return 2
}

# Basename and content patterns for files that must be encrypted to adopt.
envmgr_looks_secret() {
  local file="$1"
  local rc=0

  envmgr_looks_secret_name "$(basename -- "$file")" || rc=$?
  [[ "$rc" -ne 2 ]] && return "$rc"
  [[ -f "$file" ]] && grep -Eq -- '-----BEGIN ([A-Z]+ )?PRIVATE KEY-----' "$file" 2>/dev/null
}

envmgr_adopt_config() {
  local machine_dir="$1"
  local exact="$2"
  local encrypt="$3"
  local target=""
  local file=""
  local source=""
  local add_args=()

  shift 3
  mkdir -p -- "$machine_dir/config"

  for target in "$@"; do
    [[ -e "$target" || -L "$target" ]] || envmgr_die 1 "target does not exist: $target"
    [[ "$target" != "$(envmgr_age_key_file)" ]] || \
      envmgr_die 1 "the age key must never be committed: $target"
    if envmgr_config_is_managed "$machine_dir" "$target"; then
      source="$(envmgr_config_source_paths "$machine_dir" "$target")"
      case "$(basename -- "$source")" in
        modify_*)
          envmgr_die 1 "$target is partially managed by $source; edit that script instead"
          ;;
      esac
    fi
    [[ "$encrypt" == true ]] && continue
    while IFS= read -r file; do
      if envmgr_looks_secret "$file"; then
        envmgr_die 1 "$file looks like a secret; adopt it with --encrypt"
      fi
    done < <(find "$target" \( -type f -o -type l \) -print)
  done

  if [[ "$encrypt" == true ]]; then
    envmgr_create_age_key
    envmgr_config_prepare "$machine_dir" || return 1
    grep -Fq '[age]' "$(envmgr_config_home)/chezmoi/chezmoi.toml" 2>/dev/null || \
      envmgr_die 1 "chezmoi.toml is not managed by envmgr; run envmgr init $(basename -- "$machine_dir") first"
    add_args+=(--encrypt)
  fi
  [[ "$exact" == true ]] && add_args+=(--exact)
  if [[ "$exact" == true ]]; then
    envmgr_warn "exact directories delete unmanaged files inside them on restore"
  fi
  for target in "$@"; do
    envmgr_chezmoi "$machine_dir" add --force ${add_args[@]+"${add_args[@]}"} "$target" || return 1
    printf 'Adopted %s\n' "$(envmgr_display_path "$target")"
  done
}

envmgr_drop_config() {
  local machine_dir="$1"
  local delete="$2"
  local assume_yes="$3"
  local dry_run="$4"
  local target=""
  local source=""
  local path=""
  local files=()
  local dirs=()
  local i=0

  shift 4
  for target in "$@"; do
    envmgr_config_is_managed "$machine_dir" "$target" || \
      envmgr_die 1 "target is not managed: $target"
    source="$(envmgr_config_source_paths "$machine_dir" "$target")"
    if [[ "$delete" == true && "$(basename -- "$source")" == modify_* ]]; then
      envmgr_die 1 "$target is only partially managed; drop it without --delete and remove the managed content by hand"
    fi
  done

  if [[ "$delete" == true ]]; then
    while IFS= read -r path; do
      [[ -n "$path" ]] && files+=("$path")
    done < <(envmgr_chezmoi "$machine_dir" managed --include files,symlinks --path-style absolute "$@")
    # Deepest directories first, so parents are removed after their children.
    while IFS= read -r path; do
      [[ -n "$path" ]] && dirs+=("$path")
    done < <(envmgr_chezmoi "$machine_dir" managed --include dirs --path-style absolute "$@" | sort -r)

    printf 'config: will stop managing and delete:\n'
    for path in ${files[@]+"${files[@]}"}; do
      printf '  %s\n' "$(envmgr_display_path "$path")"
    done
  else
    printf 'config: will stop managing (local copies are kept):\n'
    printf '  %s\n' "$@"
  fi
  [[ "$dry_run" == true ]] && return 0
  if [[ "$delete" == true ]]; then
    envmgr_confirm "Delete these files?" "$assume_yes" || {
      printf 'config: drop cancelled\n'
      return 1
    }
  fi

  envmgr_chezmoi "$machine_dir" forget --force "$@" || return 1
  if [[ "$delete" == true ]]; then
    for path in ${files[@]+"${files[@]}"}; do
      if [[ -e "$path" || -L "$path" ]]; then
        rm -f -- "$path"
      fi
    done
    # Only managed directories are removed, and only when now empty.
    for ((i = 0; i < ${#dirs[@]}; i++)); do
      rmdir -- "${dirs[$i]}" 2>/dev/null || true
    done
  fi
  printf 'config: dropped %d target(s)\n' "$#"
}

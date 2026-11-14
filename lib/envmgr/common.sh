#!/usr/bin/env bash
# Shared helpers: messages, exit codes, key=value files, and local paths.

ENVMGR_EXIT_DRIFT=3
ENVMGR_EXIT_USAGE=2
ENVMGR_EXIT_REBOOT=75
ENVMGR_PARTIAL_UPGRADES_URL="https://wiki.archlinux.org/title/System_maintenance#Partial_upgrades_are_unsupported"

envmgr_die() {
  local code="$1"
  shift
  printf 'envmgr: error: %s\n' "$*" >&2
  exit "$code"
}

envmgr_warn() {
  printf 'envmgr: warning: %s\n' "$*" >&2
}

envmgr_usage_error() {
  printf 'envmgr: %s\n' "$*" >&2
  printf "Run 'envmgr --help' for usage.\n" >&2
  exit "$ENVMGR_EXIT_USAGE"
}

envmgr_config_home() {
  printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}"
}

envmgr_state_dir() {
  printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}/envmgr"
}

envmgr_local_config_file() {
  printf '%s\n' "$(envmgr_config_home)/envmgr/config"
}

envmgr_expand_path() {
  local path="$1"

  case "$path" in
    "~") printf '%s\n' "$HOME" ;;
    "~/"*) printf '%s\n' "$HOME/${path#\~/}" ;;
    *) printf '%s\n' "$path" ;;
  esac
}

# Print the value for key in a key=value file. Files are parsed, never sourced.
envmgr_kv_get() {
  local file="$1"
  local key="$2"

  [[ -r "$file" ]] || return 1
  awk -v key="$key" '
    /^[[:space:]]*(#|$)/ { next }
    {
      eq = index($0, "=")
      if (eq == 0) next
      name = substr($0, 1, eq - 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
      if (name != key) next
      value = substr($0, eq + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      found = 1
      result = value
    }
    END {
      if (!found) exit 1
      print result
    }
  ' "$file"
}

# Set key=value in a file, preserving other lines and comments.
envmgr_kv_set() {
  local file="$1"
  local key="$2"
  local value="$3"
  local tmp=""

  mkdir -p -- "$(dirname -- "$file")"
  tmp="$(mktemp "$file.XXXXXX")"
  if [[ -f "$file" ]]; then
    awk -v key="$key" -v value="$value" '
      {
        eq = index($0, "=")
        name = eq ? substr($0, 1, eq - 1) : ""
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
        if (name == key && $0 !~ /^[[:space:]]*#/) {
          if (!done) print key "=" value
          done = 1
          next
        }
        print
      }
      END { if (!done) print key "=" value }
    ' "$file" >"$tmp"
  else
    printf '%s=%s\n' "$key" "$value" >"$tmp"
  fi
  mv -f -- "$tmp" "$file"
}

envmgr_local_get() {
  local value=""

  value="$(envmgr_kv_get "$(envmgr_local_config_file)" "$1")" || return 1
  envmgr_expand_path "$value"
}

envmgr_data_dir() {
  local data=""

  data="$(envmgr_local_get data)" || \
    envmgr_die 1 "no data repository is configured; run 'envmgr setup' or 'envmgr init --data <path> <machine-id>'"
  [[ -d "$data/machines" ]] || \
    envmgr_die 1 "data repository has no machines/ directory: $data"
  printf '%s\n' "$data"
}

# Ask before a change. Returns 0 to proceed, 1 when declined.
envmgr_confirm() {
  local prompt="$1"
  local assume_yes="$2"
  local reply=""

  [[ "$assume_yes" == true ]] && return 0
  # Inside setup, answers come from its prompt input on descriptor 3.
  if [[ "${ENVMGR_PROMPT_FD:-}" == 3 ]]; then
    printf '%s [y/N] ' "$prompt" >&2
    read -r reply <&3 || reply=""
    [[ "$reply" == [Yy] || "$reply" == [Yy][Ee][Ss] ]]
    return
  fi
  if ! { : </dev/tty; } 2>/dev/null; then
    envmgr_die 1 "confirmation required but no terminal is available; rerun with --yes"
  fi
  printf '%s [y/N] ' "$prompt" >/dev/tty
  read -r reply </dev/tty || reply=""
  [[ "$reply" == [Yy] || "$reply" == [Yy][Ee][Ss] ]]
}

# Convert a target argument to an absolute path under $HOME.
envmgr_absolute_target() {
  local target=""

  target="$(envmgr_expand_path "$1")"
  [[ "$target" == /* ]] || target="$PWD/$target"
  # Normalize trailing slashes so directory arguments match Chezmoi output.
  while [[ "$target" == */ && "$target" != / ]]; do
    target="${target%/}"
  done
  [[ "$target" == "$HOME"/* ]] || envmgr_die 1 "target is not under \$HOME: $1"
  printf '%s\n' "$target"
}

# Show paths under $HOME as ~/relative for messages.
envmgr_display_path() {
  case "$1" in
    "$HOME"/*) printf '~/%s\n' "${1#"$HOME"/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

envmgr_timestamp() {
  date -u +%Y%m%dT%H%M%SZ
}

envmgr_backup_file() {
  local file="$1"
  local label="$2"
  local dir=""

  [[ -e "$file" ]] || return 0
  dir="$(envmgr_state_dir)/backups/$label-$(envmgr_timestamp)"
  mkdir -p -- "$dir"
  cp -p -- "$file" "$dir/"
  printf 'Backed up %s to %s/\n' "$file" "$dir"
}

#!/usr/bin/env bash
# Shared helpers: messages, exit codes, key=value files, and local paths.

ENVMGR_EXIT_DRIFT=3
ENVMGR_EXIT_USAGE=2
ENVMGR_EXIT_REBOOT=75

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

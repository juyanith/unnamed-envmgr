#!/usr/bin/env bash
# Detection of the running system. ENVMGR_OS, ENVMGR_DISTRIBUTION, and
# ENVMGR_ARCHITECTURE override detection, which tests rely on.

envmgr_detect_os() {
  case "$(uname -s)" in
    Linux) printf 'linux\n' ;;
    Darwin) printf 'darwin\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

envmgr_detect_distribution() {
  local os="$1"
  local distribution=""
  local variant_id=""
  local os_release_file="${ENVMGR_OS_RELEASE_FILE:-/etc/os-release}"

  if [[ "$os" == "darwin" ]]; then
    printf 'macos\n'
  elif [[ "$os" == "linux" ]] && command -v omarchy >/dev/null 2>&1; then
    printf 'omarchy\n'
  elif [[ "$os" == "linux" && -r "$os_release_file" ]]; then
    read -r distribution variant_id < <(
      # Parse instead of sourcing; values may be quoted.
      awk -F= '
        $1 == "ID" { id = $2 }
        $1 == "VARIANT_ID" { variant = $2 }
        END {
          gsub(/"/, "", id); gsub(/"/, "", variant)
          print (id == "" ? "generic-linux" : id), variant
        }
      ' "$os_release_file"
    )
    if [[ "$distribution" == "fedora" ]] && \
      { [[ "$variant_id" == "cosmic-atomic" ]] || \
        { command -v rpm-ostree >/dev/null 2>&1 && \
          { [[ "${XDG_CURRENT_DESKTOP:-}" == *COSMIC* ]] || \
            command -v cosmic-comp >/dev/null 2>&1; }; }; }; then
      printf 'fedora-cosmic-atomic\n'
    else
      printf '%s\n' "$distribution"
    fi
  else
    printf 'generic\n'
  fi
}

envmgr_detect_architecture() {
  case "$(uname -m)" in
    arm64|aarch64) printf 'apple-silicon\n' ;;
    x86_64|amd64) printf 'intel\n' ;;
    *) uname -m ;;
  esac
}

envmgr_detect_platform() {
  ENVMGR_OS="${ENVMGR_OS:-$(envmgr_detect_os)}"
  ENVMGR_DISTRIBUTION="${ENVMGR_DISTRIBUTION:-$(envmgr_detect_distribution "$ENVMGR_OS")}"
  ENVMGR_ARCHITECTURE="${ENVMGR_ARCHITECTURE:-$(envmgr_detect_architecture)}"
  export ENVMGR_OS ENVMGR_DISTRIBUTION ENVMGR_ARCHITECTURE
}

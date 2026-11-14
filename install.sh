#!/bin/bash
# Install envmgr and start envmgr setup:
#
#   curl -fsSL https://raw.githubusercontent.com/juyanith/unnamed-envmgr/main/install.sh | bash
#
# This script only makes Git usable and clones the tool. Everything else,
# including Chezmoi and the machine's packages, is done by envmgr setup and
# envmgr restore. It must run under /bin/bash 3.2 on a fresh Mac.

set -euo pipefail

die() {
  printf 'envmgr install: error: %s\n' "$*" >&2
  exit 1
}

# Install the Command Line Tools, which provide Git on macOS, and wait for
# the installer that macOS opens to finish.
install_command_line_tools() {
  xcode-select -p >/dev/null 2>&1 && return 0
  xcode-select --install >/dev/null 2>&1 || true
  printf 'Installing the Command Line Tools. Finish the dialog that macOS opened;\n'
  printf 'this continues by itself once they are installed (Ctrl-C stops).\n'
  until xcode-select -p >/dev/null 2>&1; do
    sleep "${ENVMGR_POLL_SECONDS:-5}"
  done
  printf 'The Command Line Tools are installed.\n'
}

install_git() {
  case "$(uname -s)" in
    Darwin) install_command_line_tools ;;
    *)
      command -v git >/dev/null 2>&1 && return 0
      if command -v omarchy >/dev/null 2>&1; then
        omarchy pkg add git || die "could not install git"
      else
        die "install git with this system's package manager, then run this again"
      fi
      ;;
  esac
}

# Everything runs from main, called on the last line, so a partial download
# never runs half a script.
main() {
  local url="${ENVMGR_REPO_URL:-https://github.com/juyanith/unnamed-envmgr}"
  local dir="${ENVMGR_INSTALL_DIR:-$HOME/.local/share/unnamed-envmgr}"

  install_git
  if [[ -d "$dir/.git" ]]; then
    printf 'Using the envmgr checkout in %s.\n' "$dir"
    git -C "$dir" pull --quiet --ff-only || \
      printf 'envmgr install: warning: could not update %s; using it as it is\n' "$dir" >&2
  elif [[ -e "$dir" ]]; then
    die "$dir exists and is not a Git checkout"
  else
    mkdir -p -- "$(dirname -- "$dir")"
    git clone --quiet -- "$url" "$dir" || die "could not clone $url"
    printf 'Cloned envmgr into %s.\n' "$dir"
  fi

  # Under curl | bash, standard input is the download; give setup the
  # terminal instead.
  if { : </dev/tty; } 2>/dev/null; then
    exec "$dir/bin/envmgr" setup </dev/tty
  fi
  exec "$dir/bin/envmgr" setup
}

main "$@"

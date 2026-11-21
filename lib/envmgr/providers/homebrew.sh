#!/usr/bin/env bash
# homebrew provider. Manifests: Brewfile (brew, cask, tap, mas entries),
# hold (formulae installed when missing but never upgraded), and optional
# trusted-taps (taps passed to `brew trust` before installing).

envmgr_brew_find() {
  local candidate=""

  if [[ -n "${ENVMGR_BREW:-}" && -x "$ENVMGR_BREW" ]]; then
    return 0
  fi
  for candidate in "$(command -v brew 2>/dev/null || true)" /opt/homebrew/bin/brew \
    /usr/local/bin/brew /home/linuxbrew/.linuxbrew/bin/brew; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      ENVMGR_BREW="$candidate"
      export ENVMGR_BREW
      return 0
    fi
  done
  return 1
}

# Run brew without its implicit auto-update; refresh updates explicitly.
envmgr_brew() {
  HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 "$ENVMGR_BREW" "$@"
}

# Print "kind<TAB>name" for Brewfile entries; mas names become their IDs.
envmgr_brew_entries() {
  [[ -f "$ENVMGR_MANIFEST_DIR/Brewfile" ]] || return 0
  awk '
    /^[[:space:]]*(brew|cask|tap|mas)[[:space:]]/ {
      kind = $1
      if (match($0, /"[^"]+"/) == 0) next
      name = substr($0, RSTART + 1, RLENGTH - 2)
      if (kind == "mas" && match($0, /id:[[:space:]]*[0-9]+/)) {
        id = substr($0, RSTART, RLENGTH); sub(/id:[[:space:]]*/, "", id)
        name = id " " name
      }
      print kind "\t" name
    }
  ' "$ENVMGR_MANIFEST_DIR/Brewfile"
}

envmgr_brew_held() {
  [[ -f "$ENVMGR_MANIFEST_DIR/hold" ]] || return 0
  awk '!/^[[:space:]]*(#|$)/ { print $1 }' "$ENVMGR_MANIFEST_DIR/hold"
}

envmgr_brew_is_held() {
  envmgr_brew_held | grep -Fxq -- "$1"
}

# Formulae from third-party taps are listed by their short name.
envmgr_brew_short() {
  printf '%s\n' "${1##*/}"
}

# Homebrew refuses to build formulae while an installed Xcode's license is
# not accepted. ENVMGR_XCODE overrides the Xcode location (for tests).
envmgr_brew_xcodebuild() {
  printf '%s/Contents/Developer/usr/bin/xcodebuild\n' "${ENVMGR_XCODE:-/Applications/Xcode.app}"
}

# Succeeds when Xcode is installed and its license still needs accepting.
envmgr_brew_xcode_license_pending() {
  local xcodebuild=""

  [[ "$ENVMGR_OS" == darwin ]] || return 1
  xcodebuild="$(envmgr_brew_xcodebuild)"
  [[ -x "$xcodebuild" ]] || return 1
  ! "$xcodebuild" -license check >/dev/null 2>&1
}

envmgr_brew_accept_xcode_license() {
  printf 'Accepting the Xcode license, which Homebrew requires; enter your password if asked.\n'
  sudo "$(envmgr_brew_xcodebuild)" -license accept || return 1
}

envmgr_brew_bundle() {
  HOMEBREW_BUNDLE_BREW_SKIP="${HOMEBREW_BUNDLE_BREW_SKIP:+$HOMEBREW_BUNDLE_BREW_SKIP }$1" \
    envmgr_brew bundle install --no-upgrade --file="$ENVMGR_MANIFEST_DIR/Brewfile"
}

envmgr_pkg_homebrew_available() {
  envmgr_brew_find
}

envmgr_pkg_homebrew_bootstrap() {
  local installer=""

  if [[ "$(uname -s)" == Darwin ]] && ! xcode-select -p >/dev/null 2>&1; then
    xcode-select --install || true
    printf 'Finish installing the Command Line Tools, then rerun envmgr restore.\n'
    return "$ENVMGR_EXIT_REBOOT"
  fi
  installer="$(mktemp)"
  curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o "$installer" || {
    rm -f -- "$installer"
    return 1
  }
  NONINTERACTIVE=1 /bin/bash "$installer" || {
    rm -f -- "$installer"
    return 1
  }
  rm -f -- "$installer"
  envmgr_brew_find
}

envmgr_pkg_homebrew_refresh() {
  HOMEBREW_NO_ENV_HINTS=1 "$ENVMGR_BREW" update --quiet >/dev/null
}

envmgr_pkg_homebrew_list() {
  local kind=""
  local name=""

  while IFS=$'\t' read -r kind name; do
    case "$kind" in
      brew)
        if envmgr_brew_is_held "$(envmgr_brew_short "$name")"; then
          printf '%s held\n' "$name"
        else
          printf '%s\n' "$name"
        fi
        ;;
      mas) printf '%s mas\n' "${name#* }" ;;
      *) printf '%s %s\n' "$name" "$kind" ;;
    esac
  done < <(envmgr_brew_entries)
}

envmgr_pkg_homebrew_missing() {
  local kind=""
  local name=""
  local formulae=""
  local casks=""
  local taps=""
  local apps=""

  formulae="$(envmgr_brew list --formula -1)" || return 1
  casks="$(envmgr_brew list --cask -1)" || return 1
  taps="$(envmgr_brew tap)" || return 1
  if command -v mas >/dev/null 2>&1; then
    apps="$(mas list | awk '{ print $1 }')" || apps=""
  fi
  while IFS=$'\t' read -r kind name; do
    case "$kind" in
      brew) printf '%s\n' "$formulae" | grep -Fxq -- "$(envmgr_brew_short "$name")" || printf '%s\n' "$name" ;;
      cask) printf '%s\n' "$casks" | grep -Fxq -- "$(envmgr_brew_short "$name")" || printf '%s (cask)\n' "$name" ;;
      tap) printf '%s\n' "$taps" | grep -Fxq -- "$name" || printf '%s (tap)\n' "$name" ;;
      mas) printf '%s\n' "$apps" | grep -Fxq -- "${name%% *}" || printf '%s (mas)\n' "${name#* }" ;;
    esac
  done < <(envmgr_brew_entries)
}

# Print "kind<TAB>name" for declared, unheld entries with available upgrades.
envmgr_brew_outdated() {
  local kind=""
  local name=""
  local formulae=""
  local casks=""

  formulae="$(envmgr_brew outdated --formula --quiet)" || return 1
  casks="$(envmgr_brew outdated --cask --quiet)" || return 1
  while IFS=$'\t' read -r kind name; do
    case "$kind" in
      brew)
        envmgr_brew_is_held "$(envmgr_brew_short "$name")" && continue
        printf '%s\n' "$formulae" | grep -Fxq -- "$(envmgr_brew_short "$name")" && \
          printf 'formula\t%s\n' "$name"
        ;;
      cask)
        printf '%s\n' "$casks" | grep -Fxq -- "$(envmgr_brew_short "$name")" && \
          printf 'cask\t%s\n' "$name"
        ;;
    esac
  done < <(envmgr_brew_entries)
  return 0
}

envmgr_pkg_homebrew_pending() {
  local outdated=""

  outdated="$(envmgr_brew_outdated)" || return 1
  [[ -n "$outdated" ]] && printf '%s\n' "$outdated" | awk -F'\t' '{ print $2 ($1 == "cask" ? " (cask)" : "") }'
  return 0
}

envmgr_pkg_homebrew_restore() {
  local tap=""
  local skip=""
  local name=""
  local outdated=""
  local formulae=()
  local casks=()
  local kind=""

  if [[ -f "$ENVMGR_MANIFEST_DIR/trusted-taps" ]]; then
    while read -r tap; do
      [[ -n "$tap" && "$tap" != \#* ]] || continue
      envmgr_brew tap "$tap" >/dev/null || return 1
      envmgr_brew trust "$tap" >/dev/null || return 1
    done <"$ENVMGR_MANIFEST_DIR/trusted-taps"
  fi

  # Held formulae that are installed are skipped so bundle never rebuilds them.
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if envmgr_brew list --formula "$name" >/dev/null 2>&1; then
      skip="${skip:+$skip }$name"
    fi
  done < <(envmgr_brew_held)
  if envmgr_brew_xcode_license_pending; then
    envmgr_brew_accept_xcode_license || return 1
  fi
  if [[ -f "$ENVMGR_MANIFEST_DIR/Brewfile" ]]; then
    # A mas entry can install Xcode partway through, failing the formulae
    # after it; accept the new license and run bundle once more.
    if ! envmgr_brew_bundle "$skip"; then
      envmgr_brew_xcode_license_pending || return 1
      envmgr_brew_accept_xcode_license || return 1
      envmgr_brew_bundle "$skip" || return 1
    fi
  fi

  outdated="$(envmgr_brew_outdated)" || return 1
  while IFS=$'\t' read -r kind name; do
    case "$kind" in
      formula) formulae+=("$name") ;;
      cask) casks+=("$name") ;;
    esac
  done <<<"$outdated"
  if ((${#formulae[@]})); then
    envmgr_brew upgrade --formula "${formulae[@]}" || return 1
  fi
  if ((${#casks[@]})); then
    envmgr_brew upgrade --cask "${casks[@]}" || return 1
  fi

  # compinit rejects a group-writable share directory on fresh installs.
  name="$(envmgr_brew --prefix)/share"
  [[ ! -d "$name" ]] || chmod go-w "$name" || return 1
}

envmgr_pkg_homebrew_adopt() {
  local name=""
  local kind=""

  for name in "$@"; do
    if envmgr_brew list --cask "$name" >/dev/null 2>&1; then
      kind=cask
    elif envmgr_brew list --formula "$name" >/dev/null 2>&1; then
      kind=brew
    else
      envmgr_die 1 "$name is not installed"
    fi
    if envmgr_brew_entries | grep -Fxq -- "$kind"$'\t'"$name"; then
      printf 'package/homebrew: %s is already declared\n' "$name"
      continue
    fi
    printf '%s "%s"\n' "$kind" "$name" >>"$ENVMGR_MANIFEST_DIR/Brewfile"
    printf 'package/homebrew: adopted %s %s\n' "$kind" "$name"
  done
}

envmgr_pkg_homebrew_forget() {
  envmgr_manifest_filter "$ENVMGR_MANIFEST_DIR/Brewfile" '
    BEGIN { n = split(names, list, " "); for (i = 1; i <= n; i++) drop[list[i]] = 1 }
    /^[[:space:]]*(brew|cask)[[:space:]]/ && match($0, /"[^"]+"/) {
      if (substr($0, RSTART + 1, RLENGTH - 2) in drop) next
    }
    { print }
  ' "$@"
  envmgr_manifest_filter "$ENVMGR_MANIFEST_DIR/hold" '
    BEGIN { n = split(names, list, " "); for (i = 1; i <= n; i++) drop[list[i]] = 1 }
    !($1 in drop) { print }
  ' "$@"
}

envmgr_pkg_homebrew_uninstall() {
  envmgr_brew uninstall "$@"
}

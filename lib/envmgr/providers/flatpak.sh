#!/usr/bin/env bash
# flatpak provider (user installation). Manifests: apps (one application ID
# per line) and remotes ("name url"); apps install from the first remote.

envmgr_flatpak_updates() {
  envmgr_pkg_cache flatpak-updates
}

envmgr_pkg_flatpak_available() {
  command -v flatpak >/dev/null 2>&1
}

envmgr_pkg_flatpak_bootstrap() {
  printf 'envmgr: error: flatpak is not installed; it is part of the OS image\n' >&2
  return 1
}

envmgr_pkg_flatpak_refresh() {
  local cache=""

  cache="$(envmgr_flatpak_updates)"
  flatpak remote-ls --user --updates --columns=application >"$cache.tmp" 2>/dev/null || {
    rm -f -- "$cache.tmp"
    return 1
  }
  mv -f -- "$cache.tmp" "$cache"
}

envmgr_pkg_flatpak_list() {
  envmgr_manifest_names "$ENVMGR_MANIFEST_DIR/apps"
}

envmgr_pkg_flatpak_missing() {
  local installed=""
  local app=""

  installed="$(flatpak list --user --app --columns=application)" || return 1
  while IFS= read -r app; do
    printf '%s\n' "$installed" | grep -Fxq -- "$app" || printf '%s\n' "$app"
  done < <(envmgr_pkg_flatpak_list)
}

envmgr_pkg_flatpak_pending() {
  local cache=""
  local app=""

  cache="$(envmgr_flatpak_updates)"
  [[ -s "$cache" ]] || return 0
  while IFS= read -r app; do
    grep -Fxq -- "$app" "$cache" && printf '%s\n' "$app"
  done < <(envmgr_pkg_flatpak_list)
  return 0
}

envmgr_pkg_flatpak_restore() {
  local name=""
  local url=""
  local remote=""
  local missing=""
  local pending=""
  local apps=()

  if [[ -f "$ENVMGR_MANIFEST_DIR/remotes" ]]; then
    while read -r name url; do
      [[ -n "$name" && "$name" != \#* ]] || continue
      [[ -n "$remote" ]] || remote="$name"
      flatpak remote-add --user --if-not-exists "$name" "$url" || return 1
    done <"$ENVMGR_MANIFEST_DIR/remotes"
  fi

  missing="$(envmgr_pkg_flatpak_missing)" || return 1
  if [[ -n "$missing" ]]; then
    [[ -n "$remote" ]] || {
      printf 'envmgr: error: flatpak/remotes declares no remote to install from\n' >&2
      return 1
    }
    while IFS= read -r name; do
      [[ -n "$name" ]] && apps+=("$name")
    done <<<"$missing"
    flatpak install --user --noninteractive "$remote" "${apps[@]}" || return 1
  fi

  pending="$(envmgr_pkg_flatpak_pending)"
  if [[ -n "$pending" ]]; then
    apps=()
    while IFS= read -r name; do
      [[ -n "$name" ]] && apps+=("$name")
    done <<<"$pending"
    # Updating an app also updates the runtimes it uses.
    flatpak update --user --noninteractive "${apps[@]}" || return 1
    : >"$(envmgr_flatpak_updates)"
  fi
}

envmgr_pkg_flatpak_adopt() {
  local app=""

  for app in "$@"; do
    flatpak info --user "$app" >/dev/null 2>&1 || envmgr_die 1 "$app is not installed"
    if envmgr_pkg_flatpak_list | grep -Fxq -- "$app"; then
      printf 'package/flatpak: %s is already declared\n' "$app"
      continue
    fi
    printf '%s\n' "$app" >>"$ENVMGR_MANIFEST_DIR/apps"
    printf 'package/flatpak: adopted %s\n' "$app"
  done
}

envmgr_pkg_flatpak_forget() {
  envmgr_manifest_forget "$ENVMGR_MANIFEST_DIR/apps" "$@"
}

envmgr_pkg_flatpak_uninstall() {
  flatpak uninstall --user --noninteractive "$@"
}

#!/usr/bin/env bash
# omarchy provider. Manifests: packages (repository), aur, and plugins
# ("id url [position]"). The upgrade unit is the whole system: Arch does not
# support partial upgrades, so restore runs `omarchy update` interactively.

envmgr_omarchy_updates() {
  envmgr_pkg_cache omarchy-updates
}

envmgr_pkg_omarchy_available() {
  command -v omarchy >/dev/null 2>&1 && command -v pacman >/dev/null 2>&1
}

envmgr_pkg_omarchy_bootstrap() {
  printf 'envmgr: error: the omarchy provider requires an Omarchy installation\n' >&2
  return 1
}

# checkupdates (pacman-contrib) uses a temporary database and exits 2 when
# there are no updates.
envmgr_pkg_omarchy_refresh() {
  local cache=""
  local rc=0

  cache="$(envmgr_omarchy_updates)"
  command -v checkupdates >/dev/null 2>&1 || {
    envmgr_warn "omarchy: install pacman-contrib to report pending system updates"
    : >"$cache"
    return 0
  }
  checkupdates >"$cache.tmp" 2>/dev/null || rc=$?
  case "$rc" in
    0) mv -f -- "$cache.tmp" "$cache" ;;
    2) : >"$cache"; rm -f -- "$cache.tmp" ;;
    *) rm -f -- "$cache.tmp"; return 1 ;;
  esac
}

envmgr_pkg_omarchy_list() {
  envmgr_manifest_names "$ENVMGR_MANIFEST_DIR/packages"
  envmgr_manifest_names "$ENVMGR_MANIFEST_DIR/aur" | awk '{ print $1 " aur" }'
  envmgr_manifest_names "$ENVMGR_MANIFEST_DIR/plugins" | awk '{ print $1 " plugin" }'
}

envmgr_omarchy_plugin_installed() {
  [[ -f "$HOME/.config/omarchy/plugins/$1/manifest.json" ]]
}

envmgr_pkg_omarchy_missing() {
  local installed=""
  local name=""

  installed="$(pacman -Qq)" || return 1
  while IFS= read -r name; do
    printf '%s\n' "$installed" | grep -Fxq -- "$name" || printf '%s\n' "$name"
  done < <(envmgr_manifest_names "$ENVMGR_MANIFEST_DIR/packages")
  while IFS= read -r name; do
    printf '%s\n' "$installed" | grep -Fxq -- "$name" || printf '%s (aur)\n' "$name"
  done < <(envmgr_manifest_names "$ENVMGR_MANIFEST_DIR/aur")
  while IFS= read -r name; do
    envmgr_omarchy_plugin_installed "$name" || printf '%s (plugin)\n' "$name"
  done < <(envmgr_manifest_names "$ENVMGR_MANIFEST_DIR/plugins")
}

envmgr_pkg_omarchy_pending() {
  local cache=""
  local count=0

  cache="$(envmgr_omarchy_updates)"
  [[ -s "$cache" ]] || return 0
  count="$(grep -c . "$cache")"
  printf 'system update (%d package(s))\n' "$count"
}

envmgr_pkg_omarchy_restore() {
  local missing=""
  local name=""
  local id=""
  local url=""
  local position=""
  local repo=()

  if [[ -n "$(envmgr_pkg_omarchy_pending)" ]]; then
    if [[ "${ENVMGR_ASSUME_YES:-false}" == true ]]; then
      printf 'envmgr: error: omarchy update is interactive; rerun envmgr restore without --yes\n' >&2
      return 1
    fi
    omarchy update || return 1
    : >"$(envmgr_omarchy_updates)"
  fi

  missing="$(envmgr_pkg_omarchy_missing)" || return 1
  while IFS= read -r name; do
    case "$name" in
      ""|*" (aur)"|*" (plugin)") ;;
      *) repo+=("$name") ;;
    esac
  done <<<"$missing"
  if ((${#repo[@]})); then
    omarchy pkg add "${repo[@]}" || return 1
  fi
  while IFS= read -r name; do
    case "$name" in
      *" (aur)") omarchy pkg aur add "${name% (aur)}" || return 1 ;;
    esac
  done <<<"$missing"

  [[ -f "$ENVMGR_MANIFEST_DIR/plugins" ]] || return 0
  while read -r id url position; do
    [[ -n "$id" && "$id" != \#* ]] || continue
    if envmgr_omarchy_plugin_installed "$id"; then
      omarchy plugin enable "$id" ${position:+"$position"} || return 1
    else
      omarchy plugin add "$url" --enable --yes || return 1
    fi
  done <"$ENVMGR_MANIFEST_DIR/plugins"
}

envmgr_pkg_omarchy_adopt() {
  local name=""
  local file=""

  for name in "$@"; do
    pacman -Qq "$name" >/dev/null 2>&1 || envmgr_die 1 "$name is not installed"
    file=packages
    pacman -Qmq "$name" >/dev/null 2>&1 && file=aur
    if envmgr_pkg_omarchy_list | awk '{ print $1 }' | grep -Fxq -- "$name"; then
      printf 'package/omarchy: %s is already declared\n' "$name"
      continue
    fi
    printf '%s\n' "$name" >>"$ENVMGR_MANIFEST_DIR/$file"
    printf 'package/omarchy: adopted %s (%s)\n' "$name" "$file"
  done
}

envmgr_pkg_omarchy_forget() {
  envmgr_manifest_forget "$ENVMGR_MANIFEST_DIR/packages" "$@"
  envmgr_manifest_forget "$ENVMGR_MANIFEST_DIR/aur" "$@"
  envmgr_manifest_forget "$ENVMGR_MANIFEST_DIR/plugins" "$@"
}

envmgr_pkg_omarchy_uninstall() {
  omarchy pkg remove "$@"
}

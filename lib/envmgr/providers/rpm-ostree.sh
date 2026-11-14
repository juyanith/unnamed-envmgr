#!/usr/bin/env bash
# rpm-ostree provider. Manifest: packages (layered packages, one per line).
# The upgrade unit is the whole deployment. Anything staged needs a reboot,
# so restore exits 75 after staging.

envmgr_rpm_ostree_updates() {
  envmgr_pkg_cache rpm-ostree-update
}

envmgr_pkg_rpm_ostree_available() {
  command -v rpm-ostree >/dev/null 2>&1
}

envmgr_pkg_rpm_ostree_bootstrap() {
  printf 'envmgr: error: rpm-ostree is not available; it is part of the OS image\n' >&2
  return 1
}

# `rpm-ostree upgrade --check` exits 0 when an update is available and 77
# when there is none.
envmgr_pkg_rpm_ostree_refresh() {
  local cache=""
  local rc=0

  cache="$(envmgr_rpm_ostree_updates)"
  rpm-ostree upgrade --check >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) printf 'available\n' >"$cache" ;;
    77) : >"$cache" ;;
    *) return 1 ;;
  esac
}

envmgr_pkg_rpm_ostree_list() {
  envmgr_manifest_names "$ENVMGR_MANIFEST_DIR/packages"
}

envmgr_pkg_rpm_ostree_missing() {
  local package=""

  while IFS= read -r package; do
    rpm -q "$package" >/dev/null 2>&1 || printf '%s\n' "$package"
  done < <(envmgr_pkg_rpm_ostree_list)
}

envmgr_pkg_rpm_ostree_pending() {
  [[ -s "$(envmgr_rpm_ostree_updates)" ]] && printf 'deployment update\n'
  return 0
}

envmgr_pkg_rpm_ostree_restore() {
  local missing=""
  local package=""
  local packages=()
  local staged=false
  local rc=0

  # Stage on top of an already staged deployment only after rebooting into
  # it, so that `rpm -q` reflects the layered packages.
  rpm-ostree status --pending-exit-77 >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) ;;
    77)
      printf 'A deployment is already staged. Reboot into it, then rerun envmgr restore.\n'
      return "$ENVMGR_EXIT_REBOOT"
      ;;
    *) return 1 ;;
  esac

  missing="$(envmgr_pkg_rpm_ostree_missing)" || return 1
  while IFS= read -r package; do
    [[ -n "$package" ]] && packages+=("$package")
  done <<<"$missing"
  if ((${#packages[@]})); then
    sudo rpm-ostree install --idempotent "${packages[@]}" || return 1
    staged=true
  fi
  if [[ -n "$(envmgr_pkg_rpm_ostree_pending)" ]]; then
    sudo rpm-ostree upgrade || return 1
    : >"$(envmgr_rpm_ostree_updates)"
    staged=true
  fi
  if [[ "$staged" == true ]]; then
    printf 'Reboot into the new deployment, then rerun envmgr restore.\n'
    return "$ENVMGR_EXIT_REBOOT"
  fi
}

envmgr_pkg_rpm_ostree_adopt() {
  local package=""

  for package in "$@"; do
    rpm -q "$package" >/dev/null 2>&1 || envmgr_die 1 "$package is not installed"
    if envmgr_pkg_rpm_ostree_list | grep -Fxq -- "$package"; then
      printf 'package/rpm-ostree: %s is already declared\n' "$package"
      continue
    fi
    printf '%s\n' "$package" >>"$ENVMGR_MANIFEST_DIR/packages"
    printf 'package/rpm-ostree: adopted %s\n' "$package"
  done
}

envmgr_pkg_rpm_ostree_forget() {
  envmgr_manifest_forget "$ENVMGR_MANIFEST_DIR/packages" "$@"
}

envmgr_pkg_rpm_ostree_uninstall() {
  sudo rpm-ostree uninstall "$@" || return 1
  printf 'Reboot into the new deployment to finish uninstalling.\n'
}

#!/usr/bin/env bash
# flatpak provider: not implemented yet.

envmgr_pkg_flatpak_available() {
  printf 'envmgr: error: the flatpak provider is not implemented yet\n' >&2
  return 1
}

envmgr_pkg_flatpak_list() {
  return 0
}

envmgr_pkg_flatpak_bootstrap() {
  return 1
}

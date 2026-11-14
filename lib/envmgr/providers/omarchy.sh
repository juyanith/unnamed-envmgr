#!/usr/bin/env bash
# omarchy provider: not implemented yet.

envmgr_pkg_omarchy_available() {
  printf 'envmgr: error: the omarchy provider is not implemented yet\n' >&2
  return 1
}

envmgr_pkg_omarchy_list() {
  return 0
}

envmgr_pkg_omarchy_bootstrap() {
  return 1
}

#!/usr/bin/env bash
# rpm-ostree provider: not implemented yet.

envmgr_pkg_rpm_ostree_available() {
  printf 'envmgr: error: the rpm-ostree provider is not implemented yet\n' >&2
  return 1
}

envmgr_pkg_rpm_ostree_list() {
  return 0
}

envmgr_pkg_rpm_ostree_bootstrap() {
  return 1
}

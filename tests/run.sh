#!/usr/bin/env bash
# Integration tests: run envmgr against a temporary HOME and fixture data.
# Usage: tests/run.sh [bash-binary...]   (default: /bin/bash and bash on PATH)

set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0
passes=0

if [[ $# -gt 0 ]]; then
  shells=("$@")
else
  shells=(/bin/bash "$(command -v bash)")
fi

command -v chezmoi >/dev/null 2>&1 || {
  printf 'tests require chezmoi on PATH\n' >&2
  exit 1
}

# Tests run in a subshell inside an if condition, where set -e is disabled,
# so a failed assertion must exit the subshell itself.
fail() {
  printf '    FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  [[ "$1" == "$2" ]] || fail "expected [$2], got [$1]${3:+ ($3)}"
}

assert_contains() {
  [[ "$1" == *"$2"* ]] || fail "expected output to contain [$2]; got: $1"
}

# Run envmgr; sets out and rc.
run_envmgr() {
  set +e
  out="$("$test_bash" "$root/bin/envmgr" "$@" 2>&1)"
  rc=$?
  set -e
}

cz() {
  chezmoi --source "$data/machines/$1/config" "${@:2}"
}

new_fixture() {
  local machine="$1"
  local distribution="${2:-macos}"
  local os="${3:-darwin}"

  mkdir -p "$data/machines/$machine/config"
  printf 'os=%s\ndistribution=%s\n' "$os" "$distribution" \
    >"$data/machines/$machine/machine.conf"
}

# --- tests -----------------------------------------------------------------

test_usage_errors() {
  run_envmgr
  assert_eq "$rc" 2 "no arguments"
  run_envmgr frobnicate
  assert_eq "$rc" 2 "unknown command"
  run_envmgr --help
  assert_eq "$rc" 0 "help"
}

test_init_requires_data() {
  run_envmgr init mac
  assert_eq "$rc" 1
  assert_contains "$out" "no data repository is configured"
}

test_init_selects_machine() {
  new_fixture mac
  run_envmgr init --data "$data" mac
  assert_eq "$rc" 0 "$out"
  assert_contains "$(cat "$HOME/.config/envmgr/config")" "machine=mac"
  assert_contains "$(cat "$HOME/.config/envmgr/config")" "data=$data"
  assert_contains "$(cat "$HOME/.config/chezmoi/chezmoi.toml")" \
    "sourceDir = \"$data/machines/mac/config\""
}

test_init_backs_up_existing_chezmoi_config() {
  new_fixture mac
  mkdir -p "$HOME/.config/chezmoi"
  printf '[data.platform]\nos = "darwin"\n' >"$HOME/.config/chezmoi/chezmoi.toml"
  run_envmgr init --data "$data" mac
  assert_eq "$rc" 0 "$out"
  assert_contains "$out" "Backed up"
  assert_contains "$(cat "$HOME"/.local/state/envmgr/backups/chezmoi-*/chezmoi.toml)" "data.platform"
}

test_init_refuses_distribution_mismatch() {
  new_fixture dell omarchy linux
  run_envmgr init --data "$data" dell
  assert_eq "$rc" 1
  assert_contains "$out" "expects os=linux"
  [[ ! -e "$HOME/.config/envmgr/config" ]] || \
    ! grep -q '^machine=' "$HOME/.config/envmgr/config" || fail "machine was selected"
}

test_init_data_accepts_tilde() {
  mkdir -p "$HOME/data/machines/mac/config"
  printf 'os=darwin\ndistribution=macos\n' >"$HOME/data/machines/mac/machine.conf"
  run_envmgr init --data "~/data" mac
  assert_eq "$rc" 0 "$out"
}

test_init_new_and_from() {
  new_fixture base
  printf 'hello\n' >"$data/machines/base/config/dot_hello"
  run_envmgr init --data "$data" --new fresh
  assert_eq "$rc" 0 "$out"
  assert_contains "$(cat "$data/machines/fresh/machine.conf")" "distribution=macos"
  [[ -d "$data/machines/fresh/system" ]] || fail "system/ not created"
  run_envmgr init --new copy --from base
  assert_eq "$rc" 0 "$out"
  assert_eq "$(cat "$data/machines/copy/config/dot_hello")" hello
  run_envmgr init --new copy
  assert_eq "$rc" 1 "existing machine"
  run_envmgr init --from base other
  assert_eq "$rc" 2 "--from without --new"
}

test_check_in_sync_and_drift() {
  new_fixture mac
  printf 'one\n' >"$data/machines/mac/config/dot_alpha"
  run_envmgr init --data "$data" mac
  cz mac apply --force

  run_envmgr check config
  assert_eq "$rc" 0 "$out"
  assert_contains "$out" "config: in sync"
  [[ ! -e "$HOME/.local/state/envmgr/change_summary" ]] || fail "marker present while in sync"

  # Source edit not yet restored.
  printf 'two\n' >"$data/machines/mac/config/dot_alpha"
  run_envmgr check config
  assert_eq "$rc" 3 "$out"
  assert_contains "$out" "pending  .alpha"
  assert_contains "$(cat "$HOME/.local/state/envmgr/change_summary")" "config.pending=1"
  assert_contains "$(cat "$HOME/.local/state/envmgr/change_summary")" "machine=mac"

  # Restore, then change the target locally.
  cz mac apply --force
  printf 'edited\n' >"$HOME/.alpha"
  run_envmgr check
  assert_eq "$rc" 3 "$out"
  assert_contains "$out" "local    .alpha"
  assert_contains "$(cat "$HOME/.local/state/envmgr/change_summary")" "config.local=1"

  # Resolving the drift removes the marker.
  cz mac apply --force
  run_envmgr check config
  assert_eq "$rc" 0 "$out"
  [[ ! -e "$HOME/.local/state/envmgr/change_summary" ]] || fail "marker not removed"
}

test_check_never_applied_target_is_pending() {
  new_fixture mac
  printf 'x\n' >"$data/machines/mac/config/dot_beta"
  run_envmgr init --data "$data" mac
  run_envmgr check config
  assert_eq "$rc" 3 "$out"
  assert_contains "$out" "pending  .beta"
}

test_check_rejects_bad_category() {
  new_fixture mac
  run_envmgr init --data "$data" mac
  run_envmgr check widgets
  assert_eq "$rc" 2 "$out"
}

test_check_without_machine() {
  run_envmgr check
  assert_eq "$rc" 1
}

test_list_config_kinds() {
  new_fixture mac
  mkdir -p "$data/machines/mac/config/dot_config/app"
  printf 'x\n' >"$data/machines/mac/config/dot_config/app/settings"
  cat >"$data/machines/mac/config/modify_dot_profile" <<'EOF'
#!/bin/sh
cat
EOF
  run_envmgr init --data "$data" mac
  run_envmgr list config
  assert_eq "$rc" 0 "$out"
  assert_contains "$out" "directory  .config/app"
  assert_contains "$out" "file       .config/app/settings"
  assert_contains "$out" "modify     .profile"
}

# --- runner ----------------------------------------------------------------

tests=()
while IFS= read -r name; do
  tests+=("$name")
done < <(declare -F | awk '$3 ~ /^test_/ { print $3 }')

for test_bash in "${shells[@]}"; do
  printf '%s (%s)\n' "$test_bash" "$("$test_bash" -c 'echo $BASH_VERSION')"
  for name in "${tests[@]}"; do
    work="$(mktemp -d)"
    if (
      export HOME="$work/home"
      unset XDG_CONFIG_HOME XDG_STATE_HOME XDG_DATA_HOME
      export ENVMGR_OS=darwin ENVMGR_DISTRIBUTION=macos ENVMGR_ARCHITECTURE=apple-silicon
      data="$work/data"
      mkdir -p "$HOME" "$data/machines"
      cd "$work"
      "$name"
    ); then
      passes=$((passes + 1))
      printf '  ok    %s\n' "$name"
    else
      failures=$((failures + 1))
      printf '  FAIL  %s\n' "$name"
    fi
    rm -rf "$work"
  done
done

printf '\n%d passed, %d failed\n' "$passes" "$failures"
((failures == 0))

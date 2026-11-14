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

selected_mac() {
  new_fixture mac
  run_envmgr init --data "$data" mac
  cfg="$data/machines/mac/config"
}

test_restore_applies_and_clears_marker() {
  selected_mac
  printf 'one\n' >"$cfg/dot_alpha"
  run_envmgr check
  assert_eq "$rc" 3
  run_envmgr restore config --yes
  assert_eq "$rc" 0 "$out"
  assert_eq "$(cat "$HOME/.alpha")" one
  [[ ! -e "$HOME/.local/state/envmgr/change_summary" ]] || fail "marker not cleared"
}

test_restore_dry_run_changes_nothing() {
  selected_mac
  printf 'one\n' >"$cfg/dot_alpha"
  run_envmgr restore --dry-run
  assert_eq "$rc" 0 "$out"
  assert_contains "$out" "+one"
  [[ ! -e "$HOME/.alpha" ]] || fail "dry run wrote a target"
}

test_restore_backs_up_preexisting_file() {
  selected_mac
  printf 'from envmgr\n' >"$cfg/dot_zshrc"
  printf 'original\n' >"$HOME/.zshrc"
  run_envmgr restore config --yes
  assert_eq "$rc" 0 "$out"
  assert_contains "$out" "Backed up ~/.zshrc"
  assert_eq "$(cat "$HOME"/.local/state/envmgr/backups/*/.zshrc)" original
  assert_eq "$(cat "$HOME/.zshrc")" "from envmgr"
}

test_restore_skips_backup_in_exact_dir() {
  selected_mac
  mkdir -p "$cfg/dot_config/exact_nvim" "$HOME/.config/nvim"
  printf 'managed\n' >"$cfg/dot_config/exact_nvim/init.lua"
  printf 'old\n' >"$HOME/.config/nvim/init.lua"
  printf 'stale\n' >"$HOME/.config/nvim/stale.lua"
  run_envmgr restore config --yes
  assert_eq "$rc" 0 "$out"
  [[ ! -d "$HOME/.local/state/envmgr/backups" ]] || fail "exact_ target was backed up"
  [[ ! -e "$HOME/.config/nvim/stale.lua" ]] || fail "exact_ did not remove stale file"
}

test_restore_selected_targets_only() {
  selected_mac
  printf 'a\n' >"$cfg/dot_alpha"
  printf 'b\n' >"$cfg/dot_beta"
  run_envmgr restore config "$HOME/.alpha" --yes
  assert_eq "$rc" 0 "$out"
  [[ -e "$HOME/.alpha" && ! -e "$HOME/.beta" ]] || fail "restored the wrong targets"
}

test_restore_requires_confirmation_without_terminal() {
  # Only meaningful when the test process has no controlling terminal.
  { : </dev/tty; } 2>/dev/null && return 0
  selected_mac
  printf 'a\n' >"$cfg/dot_alpha"
  run_envmgr restore config
  assert_eq "$rc" 1 "$out"
  assert_contains "$out" "rerun with --yes"
  [[ ! -e "$HOME/.alpha" ]] || fail "restored without confirmation"
}

test_restore_package_names_rejected() {
  selected_mac
  run_envmgr restore package omarchy firefox
  assert_eq "$rc" 2 "$out"
  assert_contains "$out" "does not upgrade individual packages"
  assert_contains "$out" "Partial_upgrades_are_unsupported"
}

test_restore_refuses_distribution_mismatch() {
  selected_mac
  run_envmgr restore config --yes
  ENVMGR_DISTRIBUTION=omarchy ENVMGR_OS=linux run_envmgr restore config --yes
  assert_eq "$rc" 1 "$out"
  assert_contains "$out" "expects os=darwin"
}

test_adopt_file_and_directory() {
  selected_mac
  printf 'export A=1\n' >"$HOME/.profile"
  mkdir -p "$HOME/.config/tool/sub"
  printf 'x\n' >"$HOME/.config/tool/a.conf"
  printf 'y\n' >"$HOME/.config/tool/sub/b.conf"
  run_envmgr adopt config ~/.profile "$HOME/.config/tool/"
  assert_eq "$rc" 0 "$out"
  assert_eq "$(cat "$cfg/dot_profile")" "export A=1"
  assert_eq "$(cat "$cfg/dot_config/tool/sub/b.conf")" y
  run_envmgr check config
  assert_eq "$rc" 0 "$out"
}

test_adopt_refuses_secrets() {
  selected_mac
  mkdir -p "$HOME/.ssh" "$HOME/.config/app"
  printf 'key\n' >"$HOME/.ssh/id_ed25519"
  printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n' >"$HOME/.config/app/data"
  run_envmgr adopt config "$HOME/.ssh/id_ed25519"
  assert_eq "$rc" 1 "$out"
  assert_contains "$out" "adopt it with --encrypt"
  run_envmgr adopt config "$HOME/.config/app"
  assert_eq "$rc" 1 "$out"
  assert_contains "$out" "looks like a secret"
  [[ ! -e "$cfg/dot_config/app" ]] || fail "secret directory was adopted"
}

test_adopt_refuses_partially_managed_target() {
  selected_mac
  printf '#!/bin/sh\ncat\n' >"$cfg/modify_dot_bashrc"
  printf 'x\n' >"$HOME/.bashrc"
  run_envmgr adopt config "$HOME/.bashrc"
  assert_eq "$rc" 1 "$out"
  assert_contains "$out" "partially managed"
}

test_drop_keeps_local_copy() {
  selected_mac
  printf 'a\n' >"$cfg/dot_alpha"
  run_envmgr restore config --yes
  run_envmgr drop config "$HOME/.alpha"
  assert_eq "$rc" 0 "$out"
  [[ ! -e "$cfg/dot_alpha" ]] || fail "source not removed"
  assert_eq "$(cat "$HOME/.alpha")" a
}

test_drop_delete_preserves_unmanaged_files() {
  selected_mac
  mkdir -p "$cfg/dot_config/tool/inner" "$cfg/dot_config/gone"
  printf 'm\n' >"$cfg/dot_config/tool/managed"
  printf 'n\n' >"$cfg/dot_config/tool/inner/nested"
  printf 'g\n' >"$cfg/dot_config/gone/file"
  run_envmgr restore config --yes
  printf 'mine\n' >"$HOME/.config/tool/unmanaged"
  run_envmgr drop config --delete --yes "$HOME/.config/tool" "$HOME/.config/gone"
  assert_eq "$rc" 0 "$out"
  [[ ! -e "$HOME/.config/tool/managed" ]] || fail "managed file kept"
  [[ ! -e "$HOME/.config/tool/inner" ]] || fail "empty managed directory kept"
  assert_eq "$(cat "$HOME/.config/tool/unmanaged")" mine
  [[ ! -e "$HOME/.config/gone" ]] || fail "empty managed directory kept"
  [[ -d "$HOME/.config" ]] || fail "unmanaged parent removed"
}

test_drop_delete_refuses_partial() {
  selected_mac
  printf '#!/bin/sh\ncat\n' >"$cfg/modify_dot_bashrc"
  printf 'x\n' >"$HOME/.bashrc"
  run_envmgr drop config --delete --yes "$HOME/.bashrc"
  assert_eq "$rc" 1 "$out"
  assert_eq "$(cat "$HOME/.bashrc")" x
}

test_drop_unmanaged_target_fails() {
  selected_mac
  printf 'x\n' >"$HOME/.other"
  run_envmgr drop config "$HOME/.other"
  assert_eq "$rc" 1 "$out"
}

# Create a unit: new_unit <name> <apply-body> [check-body]
new_unit() {
  local dir="$data/machines/mac/system/$1"

  mkdir -p "$dir"
  printf '#!/usr/bin/env bash\n# Unit %s\nset -euo pipefail\n%s\n' "$1" "$2" >"$dir/apply"
  chmod +x "$dir/apply"
  if [[ $# -ge 3 ]]; then
    printf '#!/usr/bin/env bash\nset -euo pipefail\n%s\n' "$3" >"$dir/check"
    chmod +x "$dir/check"
  fi
}

test_system_stamp_unit_lifecycle() {
  selected_mac
  new_unit 30-defaults 'echo applied >>"$HOME/applied.log"'
  run_envmgr check system
  assert_eq "$rc" 3 "$out"
  assert_contains "$out" "drift    30-defaults"
  assert_contains "$(cat "$HOME/.local/state/envmgr/change_summary")" "system.drift=1"

  run_envmgr restore system --yes
  assert_eq "$rc" 0 "$out"
  assert_eq "$(cat "$HOME/applied.log")" applied
  run_envmgr check system
  assert_eq "$rc" 0 "$out"
  [[ ! -e "$HOME/.local/state/envmgr/change_summary" ]] || fail "marker not cleared"

  # Already in sync: restore does not run it again.
  run_envmgr restore system --yes
  assert_contains "$out" "nothing to restore"
  assert_eq "$(grep -c applied "$HOME/applied.log")" 1

  # Editing the unit makes it drift.
  printf '# changed\n' >>"$data/machines/mac/system/30-defaults/apply"
  run_envmgr check system
  assert_eq "$rc" 3 "$out"
}

test_system_watch_file() {
  selected_mac
  mkdir -p "$HOME/.config/app"
  printf 'v1\n' >"$HOME/.config/app/a.conf"
  new_unit 60-reload 'true'
  printf '~/.config/app/*.conf\n' >"$data/machines/mac/system/60-reload/watch"
  run_envmgr restore system --yes
  assert_eq "$rc" 0 "$out"
  run_envmgr check system
  assert_eq "$rc" 0 "$out"
  printf 'v2\n' >"$HOME/.config/app/a.conf"
  run_envmgr check system
  assert_eq "$rc" 3 "$out"
}

test_system_check_script() {
  selected_mac
  new_unit 50-service 'touch "$HOME/service"' '[[ -e "$HOME/service" ]] || exit 3'
  run_envmgr check system
  assert_eq "$rc" 3 "$out"
  run_envmgr restore system --yes
  assert_eq "$rc" 0 "$out"
  run_envmgr check system
  assert_eq "$rc" 0 "$out"
  # Real checks see drift that stamps cannot.
  rm "$HOME/service"
  run_envmgr check system
  assert_eq "$rc" 3 "$out"
}

test_system_check_error() {
  selected_mac
  new_unit 50-broken 'true' 'exit 7'
  run_envmgr check system
  assert_eq "$rc" 1 "$out"
  assert_contains "$out" "error    50-broken"
}

test_system_reboot_stops_run() {
  selected_mac
  new_unit 10-first 'exit 75'
  new_unit 20-second 'touch "$HOME/second"'
  run_envmgr restore system --yes
  assert_eq "$rc" 75 "$out"
  assert_contains "$out" "requires a reboot"
  [[ ! -e "$HOME/second" ]] || fail "later unit ran after reboot request"
  run_envmgr check system
  assert_eq "$rc" 3 "$out"
}

test_system_failure_stops_run() {
  selected_mac
  new_unit 10-first 'exit 4'
  new_unit 20-second 'touch "$HOME/second"'
  run_envmgr restore system --yes
  assert_eq "$rc" 1 "$out"
  assert_contains "$out" "10-first failed (exit 4)"
  [[ ! -e "$HOME/second" ]] || fail "later unit ran after failure"
}

test_system_select_force_and_dry_run() {
  selected_mac
  new_unit 10-one 'echo one >>"$HOME/log"'
  new_unit 20-two 'echo two >>"$HOME/log"'
  run_envmgr restore system two --yes --dry-run
  assert_eq "$rc" 0 "$out"
  [[ ! -e "$HOME/log" ]] || fail "dry run applied a unit"
  run_envmgr restore system two --yes
  assert_eq "$(cat "$HOME/log")" two
  run_envmgr restore system 20-two --force --yes
  assert_eq "$(cat "$HOME/log")" "two
two"
  run_envmgr restore system missing --yes
  assert_eq "$rc" 1 "$out"
  run_envmgr restore config --force
  assert_eq "$rc" 2 "$out"
}

test_system_unit_environment_and_list() {
  selected_mac
  new_unit 40-env 'printf "%s|%s|%s\n" "$ENVMGR_MACHINE" "$(basename "$ENVMGR_UNIT_DIR")" "$PWD" >"$HOME/env"' 'exit 0'
  run_envmgr list system
  assert_eq "$rc" 0 "$out"
  assert_contains "$out" "40-env"
  assert_contains "$out" "check  Unit 40-env"
  run_envmgr restore system --force --yes
  assert_eq "$rc" 0 "$out"
  assert_eq "$(cat "$HOME/env")" "mac|40-env|$data/machines/mac/system/40-env"
}

test_system_non_executable_apply() {
  selected_mac
  new_unit 10-plain 'true'
  chmod -x "$data/machines/mac/system/10-plain/apply"
  run_envmgr restore system --yes
  assert_eq "$rc" 1 "$out"
  assert_contains "$out" "not executable"
}

test_restore_runs_config_then_system() {
  selected_mac
  printf 'cfg\n' >"$cfg/dot_unitinput"
  new_unit 50-reads-config 'cp "$HOME/.unitinput" "$HOME/copied"'
  run_envmgr restore --yes
  assert_eq "$rc" 0 "$out"
  assert_eq "$(cat "$HOME/copied")" cfg
  run_envmgr check
  assert_eq "$rc" 0 "$out"
}

use_fake_brew() {
  export FAKE_BREW_STATE="$work/brew"
  mkdir -p "$FAKE_BREW_STATE"
  export PATH="$root/tests/fakes:$PATH"
  pkgs="$data/machines/mac/packages"
  mkdir -p "$pkgs/homebrew"
}

test_homebrew_missing_and_restore() {
  selected_mac
  use_fake_brew
  printf 'jq\n' >"$FAKE_BREW_STATE/formulae"
  cat >"$pkgs/homebrew/Brewfile" <<'BREW'
tap "devsunb/tap"
brew "jq"
brew "devsunb/tap/kanata-vk-agent"
cask "zed"
BREW
  run_envmgr check package --offline
  assert_eq "$rc" 3 "$out"
  assert_contains "$out" "missing  devsunb/tap/kanata-vk-agent"
  assert_contains "$out" "missing  zed (cask)"
  assert_contains "$out" "missing  devsunb/tap (tap)"
  assert_contains "$(cat "$HOME/.local/state/envmgr/change_summary")" "package.missing=3"

  run_envmgr restore package --yes
  assert_eq "$rc" 0 "$out"
  run_envmgr check package
  assert_eq "$rc" 0 "$out"
  assert_contains "$(cat "$FAKE_BREW_STATE/log")" "update --quiet"
}

test_homebrew_upgrades_and_holds() {
  selected_mac
  use_fake_brew
  printf 'jq\nkanata\n' >"$FAKE_BREW_STATE/formulae"
  printf 'jq\nkanata\n' >"$FAKE_BREW_STATE/outdated-formulae"
  printf 'brew "jq"\nbrew "kanata", args: ["HEAD"]\n' >"$pkgs/homebrew/Brewfile"
  printf 'kanata\n' >"$pkgs/homebrew/hold"

  run_envmgr list package
  assert_contains "$out" "kanata  (held)"
  run_envmgr check package
  assert_eq "$rc" 3 "$out"
  assert_contains "$out" "pending  jq"
  [[ "$out" != *"pending  kanata"* ]] || fail "held formula reported as pending"
  assert_contains "$(cat "$HOME/.local/state/envmgr/change_summary")" "package.pending=homebrew"

  run_envmgr restore package homebrew --yes
  assert_eq "$rc" 0 "$out"
  assert_contains "$(cat "$FAKE_BREW_STATE/log")" "upgrade --formula jq"
  [[ "$(cat "$FAKE_BREW_STATE/log")" != *"upgrade --formula kanata"* ]] || fail "held formula upgraded"
  run_envmgr check package
  assert_eq "$rc" 0 "$out"
}

test_homebrew_adopt_and_drop() {
  selected_mac
  use_fake_brew
  printf 'wget\n' >"$FAKE_BREW_STATE/formulae"
  printf 'zed\n' >"$FAKE_BREW_STATE/casks"
  run_envmgr adopt package homebrew wget zed
  assert_eq "$rc" 0 "$out"
  assert_eq "$(cat "$pkgs/homebrew/Brewfile")" 'brew "wget"
cask "zed"'
  run_envmgr adopt package homebrew missing-thing
  assert_eq "$rc" 1 "$out"

  run_envmgr drop package homebrew wget
  assert_eq "$rc" 0 "$out"
  assert_eq "$(cat "$pkgs/homebrew/Brewfile")" 'cask "zed"'
  grep -Fxq wget "$FAKE_BREW_STATE/formulae" || fail "drop without --delete uninstalled"
  run_envmgr drop package --delete --yes homebrew zed
  assert_eq "$rc" 0 "$out"
  ! grep -Fxq zed "$FAKE_BREW_STATE/casks" || fail "drop --delete did not uninstall"
}

test_package_rejects_unknown_provider_directory() {
  selected_mac
  mkdir -p "$data/machines/mac/packages/apt"
  run_envmgr check package
  assert_eq "$rc" 1 "$out"
  assert_contains "$out" "unknown provider directory"
}

# Create a bare origin with one commit and print its path.
make_origin() {
  local origin="$work/origins/$1.git"
  local seed="$work/seed-$1"

  git init -q --bare -b main "$origin"
  git init -q -b main "$seed"
  printf 'one\n' >"$seed/file"
  git -C "$seed" add file
  git -C "$seed" -c user.name=t -c user.email=t@t commit -qm one
  git -C "$seed" remote add origin "$origin"
  git -C "$seed" push -q origin main
  printf '%s\n' "$origin"
}

push_commit() {
  local seed="$work/seed-$1"

  printf '%s\n' "$2" >>"$seed/file"
  git -C "$seed" -c user.name=t -c user.email=t@t commit -qam "$2"
  git -C "$seed" push -q origin main
}

test_git_provider_clone_and_fast_forward() {
  selected_mac
  local origin=""
  origin="$(make_origin tool)"
  mkdir -p "$data/machines/mac/packages/git"
  printf '%s ~/src/tool main\n' "$origin" >"$data/machines/mac/packages/git/repos"

  run_envmgr check package git
  assert_eq "$rc" 3 "$out"
  assert_contains "$out" "missing  ~/src/tool"
  run_envmgr restore package --yes
  assert_eq "$rc" 0 "$out"
  [[ -f "$HOME/src/tool/file" ]] || fail "repository not cloned"

  push_commit tool two
  run_envmgr check package
  assert_eq "$rc" 3 "$out"
  assert_contains "$out" "pending  ~/src/tool: 1 commit(s) behind"
  run_envmgr restore package --yes
  assert_eq "$rc" 0 "$out"
  assert_contains "$(cat "$HOME/src/tool/file")" two

  # Local edits block the fast-forward but do not fail the restore.
  push_commit tool three
  printf 'local\n' >>"$HOME/src/tool/file"
  run_envmgr check package
  assert_contains "$out" "blocked by uncommitted changes"
  run_envmgr restore package --yes
  assert_eq "$rc" 0 "$out"
  assert_contains "$out" "not updated: uncommitted changes"
  [[ "$(cat "$HOME/src/tool/file")" != *three* ]] || fail "dirty checkout was updated"
}

test_git_provider_adopt() {
  selected_mac
  local origin=""
  origin="$(make_origin lib)"
  git clone -q "$origin" "$HOME/src/lib"
  mkdir -p "$data/machines/mac/packages/git"
  run_envmgr adopt package git ~/src/lib
  assert_eq "$rc" 0 "$out"
  assert_eq "$(cat "$data/machines/mac/packages/git/repos")" "$origin ~/src/lib main"
  run_envmgr drop package --delete --yes git ~/src/lib
  assert_eq "$rc" 1 "$out"
  assert_contains "$out" "does not delete Git checkouts"
}

test_restore_reexecutes_after_data_update() {
  local origin=""
  origin="$(make_origin data)"
  # The data repository itself is a checkout of the origin.
  rm -rf "$data"
  git clone -q "$origin" "$data"
  mkdir -p "$data/machines/mac/config" "$data/machines/mac/packages/git"
  printf 'os=darwin\ndistribution=macos\n' >"$data/machines/mac/machine.conf"
  printf '%s %s main\n' "$origin" "$data" >"$data/machines/mac/packages/git/repos"
  git -C "$data" add -A
  git -C "$data" -c user.name=t -c user.email=t@t commit -qm machine
  git -C "$data" push -q origin main
  run_envmgr init --data "$data" mac

  # Another machine pushes a new config file.
  git clone -q "$origin" "$work/other"
  mkdir -p "$work/other/machines/mac/config"
  printf 'pulled\n' >"$work/other/machines/mac/config/dot_pulled"
  git -C "$work/other" add -A
  git -C "$work/other" -c user.name=t -c user.email=t@t commit -qm pulled
  git -C "$work/other" push -q origin main

  run_envmgr restore --yes
  assert_eq "$rc" 0 "$out"
  assert_contains "$out" "restarting restore"
  assert_eq "$(cat "$HOME/.pulled")" pulled
}

# Select a Linux machine whose providers all use the fakes in tests/fakes.
selected_linux() {
  export ENVMGR_OS=linux ENVMGR_DISTRIBUTION="$1"
  export FAKE_STATE="$work/fake"
  mkdir -p "$FAKE_STATE"
  touch "$FAKE_STATE/log"
  export PATH="$root/tests/fakes:$PATH"
  new_fixture linux "$1" linux
  run_envmgr init --data "$data" linux
  assert_eq "$rc" 0 "$out"
  pkgs="$data/machines/linux/packages"
}

test_omarchy_missing_and_restore() {
  selected_linux omarchy
  mkdir -p "$pkgs/omarchy"
  printf 'git\n# comment\nzsh\n' >"$pkgs/omarchy/packages"
  printf 'fresh-editor-bin\n' >"$pkgs/omarchy/aur"
  printf 'OmaProton https://github.com/example/OmaProton.git\n' >"$pkgs/omarchy/plugins"
  printf 'git\n' >"$FAKE_STATE/pacman-repo"

  run_envmgr list package
  assert_contains "$out" "omarchy     fresh-editor-bin  (aur)"
  assert_contains "$out" "omarchy     OmaProton  (plugin)"
  run_envmgr check package
  assert_eq "$rc" 3 "$out"
  assert_contains "$out" "missing  zsh"
  assert_contains "$out" "missing  fresh-editor-bin (aur)"
  assert_contains "$out" "missing  OmaProton (plugin)"

  run_envmgr restore package --yes
  assert_eq "$rc" 0 "$out"
  assert_contains "$(cat "$FAKE_STATE/log")" "omarchy pkg add zsh"
  assert_contains "$(cat "$FAKE_STATE/log")" "omarchy pkg aur add fresh-editor-bin"
  assert_contains "$(cat "$FAKE_STATE/log")" "omarchy plugin add https://github.com/example/OmaProton.git --enable --yes"
  run_envmgr check package
  assert_eq "$rc" 0 "$out"
  run_envmgr restore package --yes
  assert_contains "$out" "nothing to restore"
}

test_omarchy_system_update_is_interactive() {
  selected_linux omarchy
  mkdir -p "$pkgs/omarchy"
  printf 'git\n' >"$pkgs/omarchy/packages"
  printf 'git\n' >"$FAKE_STATE/pacman-repo"
  printf 'linux 6.1-1 -> 6.2-1\nmesa 1 -> 2\n' >"$FAKE_STATE/updates"

  run_envmgr check package
  assert_eq "$rc" 3 "$out"
  assert_contains "$out" "pending  system update (2 package(s))"
  run_envmgr check package --offline
  assert_contains "$out" "pending  system update (2 package(s))"

  run_envmgr restore package --yes
  assert_eq "$rc" 1 "$out"
  assert_contains "$out" "rerun envmgr restore without --yes"
  [[ "$(cat "$FAKE_STATE/log")" != *"omarchy update"* ]] || fail "ran omarchy update with --yes"

  run_envmgr restore package omarchy zsh
  assert_eq "$rc" 2 "$out"
  assert_contains "$out" "System_maintenance#Partial_upgrades_are_unsupported"
}

test_omarchy_adopt_sorts_aur_and_drop() {
  selected_linux omarchy
  printf 'ripgrep\n' >"$FAKE_STATE/pacman-repo"
  printf 'kanata-bin\n' >"$FAKE_STATE/pacman-aur"
  run_envmgr adopt package omarchy ripgrep kanata-bin
  assert_eq "$rc" 0 "$out"
  assert_eq "$(cat "$pkgs/omarchy/packages")" ripgrep
  assert_eq "$(cat "$pkgs/omarchy/aur")" kanata-bin
  run_envmgr adopt package omarchy ripgrep
  assert_contains "$out" "already declared"
  run_envmgr adopt package omarchy not-installed
  assert_eq "$rc" 1 "$out"

  run_envmgr drop package --delete --yes omarchy kanata-bin
  assert_eq "$rc" 0 "$out"
  assert_eq "$(cat "$pkgs/omarchy/aur")" ""
  ! grep -Fxq kanata-bin "$FAKE_STATE/pacman-aur" || fail "drop --delete did not uninstall"
}

test_flatpak_install_and_update() {
  selected_linux fedora-cosmic-atomic
  mkdir -p "$pkgs/flatpak"
  printf 'flathub https://dl.flathub.org/repo/flathub.flatpakrepo\n' >"$pkgs/flatpak/remotes"
  printf 'dev.zed.Zed\ncom.visualstudio.code\n' >"$pkgs/flatpak/apps"
  printf 'com.visualstudio.code\norg.example.Undeclared\n' >"$FAKE_STATE/flatpak-apps"
  printf 'com.visualstudio.code\norg.example.Undeclared\n' >"$FAKE_STATE/flatpak-updates"

  run_envmgr check package
  assert_eq "$rc" 3 "$out"
  assert_contains "$out" "missing  dev.zed.Zed"
  assert_contains "$out" "pending  com.visualstudio.code"
  [[ "$out" != *"org.example.Undeclared"* ]] || fail "undeclared app reported"

  run_envmgr restore package --yes
  assert_eq "$rc" 0 "$out"
  assert_contains "$(cat "$FAKE_STATE/log")" "flatpak remote-add --user --if-not-exists flathub"
  assert_contains "$(cat "$FAKE_STATE/log")" "flatpak install --user --noninteractive flathub dev.zed.Zed"
  assert_contains "$(cat "$FAKE_STATE/log")" "flatpak update --user --noninteractive com.visualstudio.code"
  [[ "$(cat "$FAKE_STATE/log")" != *"update --user --noninteractive org.example"* ]] || \
    fail "updated an undeclared app"
  run_envmgr check package
  assert_eq "$rc" 0 "$out"
}

test_flatpak_adopt_and_drop() {
  selected_linux fedora-cosmic-atomic
  printf 'dev.zed.Zed\n' >"$FAKE_STATE/flatpak-apps"
  run_envmgr adopt package flatpak dev.zed.Zed
  assert_eq "$rc" 0 "$out"
  assert_eq "$(cat "$pkgs/flatpak/apps")" dev.zed.Zed
  run_envmgr drop package --delete --yes flatpak dev.zed.Zed
  assert_eq "$rc" 0 "$out"
  assert_eq "$(cat "$FAKE_STATE/flatpak-apps")" ""
}

test_rpm_ostree_stages_and_requests_reboot() {
  selected_linux fedora-cosmic-atomic
  mkdir -p "$pkgs/rpm-ostree"
  printf 'zsh\nkanata\n' >"$pkgs/rpm-ostree/packages"
  printf 'zsh\n' >"$FAKE_STATE/rpm-installed"
  printf 'available\n' >"$FAKE_STATE/ostree-update"

  run_envmgr check package
  assert_eq "$rc" 3 "$out"
  assert_contains "$out" "missing  kanata"
  assert_contains "$out" "pending  deployment update"

  run_envmgr restore --yes
  assert_eq "$rc" 75 "$out"
  assert_contains "$out" "Reboot into the new deployment"
  assert_contains "$(cat "$FAKE_STATE/log")" "rpm-ostree install --idempotent kanata"
  assert_contains "$(cat "$FAKE_STATE/log")" "rpm-ostree upgrade"

  # Until the reboot, restore stops before staging anything else.
  : >"$FAKE_STATE/log"
  run_envmgr restore --yes
  assert_eq "$rc" 75 "$out"
  assert_contains "$out" "already staged"
  [[ "$(cat "$FAKE_STATE/log")" != *"install"* ]] || fail "staged again before reboot"

  # Simulate the reboot.
  rm -f "$FAKE_STATE/ostree-pending"
  cat "$FAKE_STATE/rpm-staged" >>"$FAKE_STATE/rpm-installed"
  run_envmgr restore --yes
  assert_eq "$rc" 0 "$out"
  run_envmgr check package
  assert_eq "$rc" 0 "$out"
}

test_rpm_ostree_adopt() {
  selected_linux fedora-cosmic-atomic
  printf 'zsh\n' >"$FAKE_STATE/rpm-installed"
  run_envmgr adopt package rpm-ostree zsh
  assert_eq "$rc" 0 "$out"
  assert_eq "$(cat "$pkgs/rpm-ostree/packages")" zsh
  run_envmgr adopt package rpm-ostree missing
  assert_eq "$rc" 1 "$out"
}

# Create a data origin with one machine for this platform; sets data_origin.
make_data_origin() {
  local seed="$work/data-seed"

  data_origin="$work/origins/data.git"
  git init -q --bare -b main "$data_origin"
  git init -q -b main "$seed"
  mkdir -p "$seed/machines/mac/config" "$seed/machines/other/config"
  printf 'os=darwin\ndistribution=macos\ndescription=Desk Mac\n' >"$seed/machines/mac/machine.conf"
  printf 'os=linux\ndistribution=omarchy\n' >"$seed/machines/other/machine.conf"
  printf 'x\n' >"$seed/machines/mac/config/dot_x"
  git -C "$seed" add -A
  git -C "$seed" -c user.name=t -c user.email=t@t commit -qm data
  git -C "$seed" remote add origin "$data_origin"
  git -C "$seed" push -q origin main
}

# Run setup with scripted answers, one per line.
run_setup() {
  printf '%s\n' "$@" >"$work/answers"
  ENVMGR_TTY="$work/answers" run_envmgr setup
}

test_setup_clones_and_selects_machine() {
  make_data_origin
  run_setup "$data_origin" "~/Work/data" 1 codex
  assert_eq "$rc" 0 "$out"
  assert_contains "$out" "1) mac  Desk Mac"
  [[ "$out" != *"other"* ]] || fail "offered a machine for another platform"
  assert_contains "$out" "Selected machine mac"
  assert_contains "$out" "does not use SSH"
  [[ -d "$HOME/Work/data/machines/mac" ]] || fail "data not cloned"
  [[ "$(readlink "$HOME/.local/bin/envmgr")" == "$root/bin/envmgr" ]] || fail "envmgr not linked"
  local config="$HOME/.config/envmgr/config"
  assert_contains "$(cat "$config")" "data=~/Work/data"
  assert_contains "$(cat "$config")" "data_url=$data_origin"
  assert_contains "$(cat "$config")" "machine=mac"
  assert_contains "$(cat "$config")" "agent=codex"

  # A second run asks nothing and changes nothing.
  cp "$config" "$work/config.before"
  run_setup
  assert_eq "$rc" 0 "$out"
  assert_contains "$out" "This machine is mac."
  assert_contains "$out" "Agent for envmgr evaluate: codex"
  assert_eq "$(cat "$config")" "$(cat "$work/config.before")"
}

test_setup_new_machine_and_skip() {
  make_data_origin
  run_setup "$data_origin" "" bogus n laptop mac ""
  assert_eq "$rc" 0 "$out"
  assert_contains "$out" "Enter a number, n, or s."
  assert_contains "$out" "Created machine laptop from mac."
  [[ -f "$HOME/Work/Git/envmgr-data/machines/laptop/config/dot_x" ]] || fail "machine not copied"
  assert_contains "$(cat "$HOME/.config/envmgr/config")" "machine=laptop"
  assert_contains "$(cat "$HOME/.config/envmgr/config")" "agent="

  rm -rf "$HOME/.config/envmgr" "$HOME/Work"
  run_setup "$data_origin" "" s ""
  assert_eq "$rc" 0 "$out"
  assert_contains "$out" "Skipped."
  [[ "$(cat "$HOME/.config/envmgr/config")" != *"machine="* ]] || fail "skip selected a machine"
}

test_setup_backs_up_existing_link() {
  make_data_origin
  mkdir -p "$HOME/.local/bin"
  printf 'old\n' >"$HOME/.local/bin/envmgr"
  run_setup "$data_origin" "" s ""
  assert_eq "$rc" 0 "$out"
  assert_contains "$out" "Backed up"
  [[ -L "$HOME/.local/bin/envmgr" ]] || fail "envmgr not linked"
}

test_setup_guides_github_ssh() {
  make_data_origin
  export FAKE_STATE="$work/fake"
  mkdir -p "$FAKE_STATE"
  export PATH="$root/tests/fakes-ssh:$PATH"
  git clone -q "$data_origin" "$HOME/Work/Git/envmgr-data"

  run_setup "git@github.com:someone/data.git" "" n
  assert_eq "$rc" 1 "$out"
  assert_contains "$out" "ssh-ed25519 AAAAfake test"
  assert_contains "$out" "https://github.com/settings/ssh/new"
  assert_contains "$out" "rerun envmgr setup"
  [[ -f "$HOME/.ssh/id_ed25519" ]] || fail "no key created"

  touch "$FAKE_STATE/ssh-ok"
  run_setup "git@github.com:someone/data.git" "" s ""
  assert_eq "$rc" 0 "$out"
  assert_contains "$out" "GitHub accepts this machine's SSH key."
  assert_contains "$out" "Using existing checkout"
  assert_contains "$(cat "$HOME/.config/envmgr/config")" "data_url=git@github.com:someone/data.git"
}

test_setup_requires_terminal() {
  ENVMGR_TTY="$work/missing" run_envmgr setup
  assert_eq "$rc" 1 "$out"
  assert_contains "$out" "needs a terminal"
}

test_setup_guards_existing_chezmoi_source() {
  make_data_origin
  mkdir -p "$work/legacy/home" "$HOME/.config/chezmoi"
  printf 'sourceDir = "%s"\n' "$work/legacy/home" >"$HOME/.config/chezmoi/chezmoi.toml"
  cp "$HOME/.config/chezmoi/chezmoi.toml" "$work/toml.before"

  run_setup "$data_origin" "" 1 n s ""
  assert_eq "$rc" 0 "$out"
  assert_contains "$out" "Chezmoi currently uses $work/legacy/home."
  assert_contains "$out" "choose s"
  assert_contains "$out" "Chezmoi still uses $work/legacy/home."
  assert_contains "$out" "Skipped."
  assert_eq "$(cat "$HOME/.config/chezmoi/chezmoi.toml")" "$(cat "$work/toml.before")"
  [[ "$(cat "$HOME/.config/envmgr/config")" != *"machine="* ]] || fail "selected a machine"

  run_setup 1 y
  assert_eq "$rc" 0 "$out"
  assert_contains "$out" "Selected machine mac"
  assert_contains "$(cat "$HOME/.config/chezmoi/chezmoi.toml")" "machines/mac/config"
}

test_adopt_encrypt() {
  selected_mac
  local key="$HOME/.config/envmgr/age.key"
  mkdir -p "$HOME/.ssh"
  printf 'very-secret\n' >"$HOME/.ssh/id_ed25519"
  run_envmgr adopt config --encrypt "$HOME/.ssh/id_ed25519"
  assert_eq "$rc" 0 "$out"
  assert_contains "$out" "Created the age key"
  [[ "$(ls -l "$key" | cut -c1-10)" == "-rw-------" ]] || fail "age key is not private"
  local source=""
  source="$(find "$cfg" -name 'encrypted_*')"
  [[ -n "$source" ]] || fail "no encrypted source"
  ! grep -q very-secret "$source" || fail "source holds plaintext"
  assert_contains "$(cat "$HOME/.config/chezmoi/chezmoi.toml")" 'encryption = "age"'
  run_envmgr check config
  assert_eq "$rc" 0 "$out"
  run_envmgr list config
  assert_contains "$out" "encrypted  .ssh/id_ed25519"

  rm "$HOME/.ssh/id_ed25519"
  run_envmgr restore config --yes
  assert_eq "$rc" 0 "$out"
  assert_eq "$(cat "$HOME/.ssh/id_ed25519")" very-secret

  # A second adoption reuses the key; the key itself is never adopted.
  printf 'token\n' >"$HOME/.netrc"
  run_envmgr adopt config --encrypt "$HOME/.netrc"
  assert_eq "$rc" 0 "$out"
  [[ "$out" != *"Created the age key"* ]] || fail "key recreated"
  run_envmgr adopt config --encrypt "$key"
  assert_eq "$rc" 1 "$out"
  assert_contains "$out" "must never be committed"
}

test_encrypted_files_need_the_key() {
  selected_mac
  printf 'very-secret\n' >"$HOME/.netrc"
  run_envmgr adopt config --encrypt "$HOME/.netrc"
  assert_eq "$rc" 0 "$out"

  # A machine without the key gets an explanation instead of a Chezmoi error.
  mv "$HOME/.config/envmgr/age.key" "$work/age.key"
  run_envmgr check config
  assert_eq "$rc" 1 "$out"
  assert_contains "$out" "the age key is missing"
  run_envmgr restore config --yes
  assert_eq "$rc" 1 "$out"
  assert_contains "$out" "the age key is missing"

  # Without the key, encrypted targets keep their names and can be dropped.
  run_envmgr list config
  assert_contains "$out" "encrypted  .netrc"
  [[ "$out" != *".netrc.age"* ]] || fail "target lost its name"
  cp -R "$cfg" "$work/cfg.keep"
  cp "$HOME/.netrc" "$work/netrc.keep"
  run_envmgr drop config --delete --yes "$HOME/.netrc"
  assert_eq "$rc" 0 "$out"
  [[ ! -e "$HOME/.netrc" ]] || fail "target not deleted"
  run_envmgr check config
  assert_eq "$rc" 0 "$out"
  rm -rf "$cfg" && mv "$work/cfg.keep" "$cfg"
  mv "$work/netrc.keep" "$HOME/.netrc"

  # Once the key is copied in, envmgr adds the age settings to chezmoi.toml.
  printf '# Managed by envmgr; changed by envmgr init.\nsourceDir = "%s"\n' "$cfg" \
    >"$HOME/.config/chezmoi/chezmoi.toml"
  mv "$work/age.key" "$HOME/.config/envmgr/age.key"
  run_envmgr check config
  assert_eq "$rc" 0 "$out"
  assert_contains "$(cat "$HOME/.config/chezmoi/chezmoi.toml")" '[age]'
}

# Agent stand-in: records its directory and arguments.
make_agent() {
  mkdir -p "$work/bin"
  cat >"$work/bin/agent" <<'AGENT'
#!/bin/sh
[ -d machines/mac ] && echo in-data >"$work/agent.dir"
printf '%s\n---\n' "$@" >"$work/agent.args"
exit "${FAKE_AGENT_RC:-0}"
AGENT
  chmod +x "$work/bin/agent"
}

test_evaluate_starts_agent() {
  selected_mac
  run_envmgr evaluate
  assert_eq "$rc" 1 "$out"
  assert_contains "$out" "no agent is configured"

  printf 'agent=missing-agent\n' >>"$HOME/.config/envmgr/config"
  run_envmgr evaluate
  assert_eq "$rc" 1 "$out"
  assert_contains "$out" "agent command not found"

  make_agent
  sed -i.bak '/^agent=/d' "$HOME/.config/envmgr/config"
  printf 'agent=%s --flag\n' "$work/bin/agent" >>"$HOME/.config/envmgr/config"
  printf 'private-content\n' >"$cfg/dot_alpha"
  run_envmgr evaluate config
  assert_eq "$rc" 0 "$out"
  assert_contains "$out" "pending  .alpha"
  assert_eq "$(cat "$work/agent.dir")" in-data
  local args=""
  args="$(cat "$work/agent.args")"
  assert_eq "$(head -n 1 "$work/agent.args")" --flag
  assert_contains "$args" 'envmgr machine "mac"'
  assert_contains "$args" "machines/mac/SPEC.md"
  assert_contains "$args" '`envmgr check config` (exit 3'
  assert_contains "$args" "pending  .alpha"
  assert_contains "$args" "Do not run envmgr restore"
  [[ "$args" != *private-content* ]] || fail "prompt includes target contents"

  FAKE_AGENT_RC=7 run_envmgr evaluate
  assert_eq "$rc" 7 "$out"
}

# Clone a data origin into $data with one machine selected and a git
# provider entry for the data repository itself.
data_checkout() {
  make_data_origin
  rm -rf "$data"
  git clone -q "$data_origin" "$data"
  mkdir -p "$data/machines/mac/packages/git"
  printf '%s %s main\n' "$data_origin" "$data" >"$data/machines/mac/packages/git/repos"
  git -C "$data" add -A
  git -C "$data" -c user.name=t -c user.email=t@t commit -qm repos
  git -C "$data" push -q origin main
  run_envmgr init --data "$data" mac
}

test_migrate_moves_repository() {
  data_checkout
  git -C "$data" branch feature
  git -C "$data" push -q -u origin feature
  git -C "$data" tag v1
  git -C "$data" push -q origin v1
  local new="$work/origins/new.git"
  git init -q --bare -b main "$new"

  printf 'dirty\n' >"$data/dirty"
  run_envmgr migrate "$new" --yes
  assert_eq "$rc" 1 "$out"
  assert_contains "$out" "uncommitted changes"
  rm "$data/dirty"

  git -C "$data" -c user.name=t -c user.email=t@t commit -q --allow-empty -m local
  run_envmgr migrate "$new" --yes
  assert_eq "$rc" 1 "$out"
  assert_contains "$out" "branch main has 1 unpushed commit(s)"
  git -C "$data" push -q origin main

  run_envmgr migrate "$data_origin" --yes
  assert_eq "$rc" 0 "$out"
  assert_contains "$out" "origin already is"
  run_envmgr migrate "$work/origins/data.git/../data.git" --yes
  assert_eq "$rc" 1 "$out"
  assert_contains "$out" "is not empty"

  run_envmgr migrate "$new" --dry-run
  assert_eq "$rc" 0 "$out"
  assert_contains "$out" "branches  feature main"
  assert_contains "$out" "tags      1"
  assert_eq "$(git ls-remote "$new")" "" "dry run pushed"

  run_envmgr migrate "$new" --yes
  assert_eq "$rc" 0 "$out"
  local refs=""
  refs="$(git ls-remote "$new")"
  assert_contains "$refs" "refs/heads/main"
  assert_contains "$refs" "refs/heads/feature"
  assert_contains "$refs" "refs/tags/v1"
  [[ "$refs" != *refs/remotes* ]] || fail "pushed remote-tracking refs"
  assert_eq "$(git -C "$data" remote get-url origin)" "$new"
  assert_contains "$(cat "$HOME/.config/envmgr/config")" "data_url=$new"
  assert_eq "$(cat "$data/machines/mac/packages/git/repos")" "$new $data main"
  assert_contains "$out" "machines/mac/packages/git/repos"
  assert_contains "$out" "envmgr migrate --follow $new"
  [[ -n "$(git ls-remote "$data_origin")" ]] || fail "old remote changed"
}

test_migrate_follow() {
  data_checkout
  local new="$work/origins/new.git"
  git init -q --bare -b main "$new"

  git -C "$data" -c user.name=t -c user.email=t@t commit -q --allow-empty -m unpushed
  git -C "$data" push -q "$new" origin/main:refs/heads/main
  run_envmgr migrate --follow "$new"
  assert_eq "$rc" 1 "$out"
  assert_contains "$out" "does not contain this checkout's HEAD"
  assert_eq "$(git -C "$data" remote get-url origin)" "$data_origin"

  git -C "$data" reset -q --hard origin/main
  run_envmgr migrate --follow "$new" --dry-run
  assert_eq "$rc" 0 "$out"
  assert_eq "$(git -C "$data" remote get-url origin)" "$data_origin"
  run_envmgr migrate --follow "$new"
  assert_eq "$rc" 0 "$out"
  assert_eq "$(git -C "$data" remote get-url origin)" "$new"
  assert_contains "$(cat "$HOME/.config/envmgr/config")" "data_url=$new"
  assert_eq "$(git -C "$data" for-each-ref refs/envmgr-follow)" "" "temporary refs left"
}

test_migrate_no_history() {
  data_checkout
  run_envmgr restore config --yes
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  git -C "$data" branch feature
  git -C "$data" push -q -u origin feature
  git -C "$data" tag v1
  git -C "$data" push -q origin v1
  local new="$work/origins/new.git"
  local tree=""
  git init -q --bare -b main "$new"
  tree="$(git -C "$data" rev-parse 'origin/main^{tree}')"

  run_envmgr migrate --no-history "$new" --dry-run
  assert_eq "$rc" 0 "$out"
  assert_contains "$out" "omitted   history, 1 tag(s), other branches: feature"
  assert_eq "$(git ls-remote "$new")" "" "dry run pushed"

  run_envmgr migrate --no-history "$new" --yes
  assert_eq "$rc" 0 "$out"
  local refs=""
  refs="$(git ls-remote "$new")"
  assert_contains "$refs" "refs/heads/main"
  [[ "$refs" != *feature* && "$refs" != *refs/tags* ]] || fail "copied more than main: $refs"
  assert_eq "$(git --git-dir="$new" rev-list --count main)" 1
  assert_eq "$(git --git-dir="$new" rev-parse 'main^{tree}')" "$tree"
  assert_eq "$(git -C "$data" remote get-url origin)" "$new"
  [[ -d "$(echo "$data".old-*)/.git" ]] || fail "old checkout not kept"
  assert_contains "$(cat "$HOME/.config/envmgr/config")" "data_url=$new"
  assert_eq "$(cat "$data/machines/mac/packages/git/repos")" "$new $data main"
  run_envmgr check config
  assert_eq "$rc" 0 "$out"
}

test_migrate_follow_clean_copy() {
  data_checkout
  run_envmgr restore config --yes
  local new="$work/origins/new.git"
  local copy=""
  git init -q --bare -b main "$new"
  copy="$(git -C "$data" -c user.name=t -c user.email=t@t commit-tree -m copy 'origin/main^{tree}')"
  git -C "$data" push -q "$new" "$copy:refs/heads/main"

  printf 'dirty\n' >"$data/dirty"
  run_envmgr migrate --follow "$new" --yes
  assert_eq "$rc" 1 "$out"
  assert_contains "$out" "uncommitted changes"
  rm "$data/dirty"

  run_envmgr migrate --follow "$new" --dry-run
  assert_eq "$rc" 0 "$out"
  assert_contains "$out" "is a copy without this checkout's history"
  assert_eq "$(git -C "$data" remote get-url origin)" "$data_origin"

  run_envmgr migrate --follow "$new" --yes
  assert_eq "$rc" 0 "$out"
  assert_eq "$(git -C "$data" remote get-url origin)" "$new"
  assert_eq "$(git -C "$data" rev-parse HEAD)" "$copy"
  [[ -d "$(echo "$data".old-*)/.git" ]] || fail "old checkout not kept"
  assert_contains "$(cat "$HOME/.config/envmgr/config")" "machine=mac"
  run_envmgr check config
  assert_eq "$rc" 0 "$out"

  run_envmgr migrate --follow --no-history "$new"
  assert_eq "$rc" 2 "$out"
}

test_setup_reports_missing_age_key() {
  make_data_origin
  git clone -q "$data_origin" "$work/seed2"
  printf 'x\n' >"$work/seed2/machines/mac/config/encrypted_dot_secret.age"
  git -C "$work/seed2" add -A
  git -C "$work/seed2" -c user.name=t -c user.email=t@t commit -qm enc
  git -C "$work/seed2" push -q origin main
  run_setup "$data_origin" "" 1 ""
  assert_eq "$rc" 0 "$out"
  assert_contains "$out" "has encrypted files"
  assert_contains "$out" "~/.config/envmgr/age.key"
}

test_save_commits_and_pushes() {
  data_checkout
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  run_envmgr save --yes
  assert_eq "$rc" 0 "$out"
  assert_contains "$out" "nothing to save for mac"

  mkdir -p "$HOME/.config/example"
  printf 'a\n' >"$HOME/.config/example/a.toml"
  run_envmgr adopt config "$HOME/.config/example"
  assert_eq "$rc" 0 "$out"
  printf 'brew\n' >"$data/machines/mac/packages/git/extra"
  printf 'other\n' >"$data/machines/other/note"
  printf 'staged\n' >"$data/top"
  git -C "$data" add top

  run_envmgr save --dry-run
  assert_eq "$rc" 0 "$out"
  assert_contains "$out" "config/dot_config/example/a.toml"
  assert_contains "$out" "config: dot_config/example/a.toml"
  assert_contains "$out" "package: git"
  assert_contains "$out" "machines/other/"
  assert_eq "$(git -C "$data" rev-list --count origin/main..HEAD)" 0 "dry run committed"

  run_envmgr save
  assert_eq "$rc" 1 "$out"
  assert_contains "$out" "rerun with --yes"

  run_envmgr save --yes
  assert_eq "$rc" 0 "$out"
  assert_contains "$out" "pushed to origin/main"
  assert_eq "$(git -C "$data" rev-parse HEAD)" "$(git --git-dir="$data_origin" rev-parse main)"
  assert_eq "$(git -C "$data" log -1 --format=%s)" "Update mac"
  assert_contains "$(git -C "$data" show --stat HEAD)" "dot_config/example/a.toml"
  [[ "$(git -C "$data" show --stat HEAD)" != *other/note* ]] || fail "committed another machine"
  assert_eq "$(git -C "$data" diff --cached --name-only)" top "other staged change kept"
  assert_contains "$(git -C "$data" status --porcelain)" "?? machines/other/"

  printf 'b\n' >"$HOME/.config/example/a.toml"
  run_envmgr adopt config "$HOME/.config/example/a.toml"
  run_envmgr save --no-push -m "Tweak example" --yes
  assert_eq "$rc" 0 "$out"
  assert_eq "$(git -C "$data" log -1 --format=%s)" "Tweak example"
  assert_eq "$(git -C "$data" rev-list --count origin/main..HEAD)" 1
  # A later save pushes earlier commits even with nothing new to commit.
  run_envmgr save --yes
  assert_eq "$rc" 0 "$out"
  assert_contains "$out" "1 earlier commit(s) are not pushed yet"
  assert_eq "$(git -C "$data" rev-list --count origin/main..HEAD)" 0
}

test_save_rebases_onto_other_machines() {
  data_checkout
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  git clone -q "$data_origin" "$work/second"
  printf 'y\n' >"$work/second/machines/other/dot_y"
  git -C "$work/second" add -A
  git -C "$work/second" commit -qm other
  git -C "$work/second" push -q origin main

  printf 'z\n' >"$data/machines/mac/config/dot_z"
  printf 'dirty\n' >>"$data/machines/other/machine.conf"
  printf 'untracked\n' >"$data/README"
  run_envmgr save --yes
  assert_eq "$rc" 1 "$out"
  assert_contains "$out" "would block pulling them"
  assert_eq "$(git -C "$data" rev-list --count origin/main..HEAD)" 0 "committed before refusing"
  git -C "$data" checkout -q -- machines/other/machine.conf

  run_envmgr save --yes
  assert_eq "$rc" 0 "$out"
  assert_contains "$out" "origin has 1 new commit(s)"
  assert_eq "$(git -C "$data" rev-parse HEAD)" "$(git --git-dir="$data_origin" rev-parse main)"
  [[ -f "$data/machines/other/dot_y" ]] || fail "did not rebase onto origin"

  # Local commits outside the machine directory are left to the user.
  git -C "$work/second" pull -q
  printf 'w\n' >"$work/second/machines/other/dot_w"
  git -C "$work/second" add -A
  git -C "$work/second" commit -qm other2
  git -C "$work/second" push -q origin main
  printf 'top\n' >"$data/top"
  git -C "$data" add top
  git -C "$data" commit -qm top
  printf 'z2\n' >"$data/machines/mac/config/dot_z"
  run_envmgr save --yes
  assert_eq "$rc" 1 "$out"
  assert_contains "$out" "local commits change files outside machines/mac"
}

test_save_conflict_keeps_local_commit() {
  data_checkout
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  git clone -q "$data_origin" "$work/second"
  printf 'theirs\n' >"$work/second/machines/mac/config/dot_x"
  git -C "$work/second" commit -qam theirs
  git -C "$work/second" push -q origin main

  printf 'ours\n' >"$data/machines/mac/config/dot_x"
  run_envmgr save --yes
  assert_eq "$rc" 1 "$out"
  assert_contains "$out" "the commit is local only"
  assert_eq "$(git -C "$data" branch --show-current)" main "rebase not aborted"
  assert_eq "$(git -C "$data" rev-list --count origin/main..HEAD)" 1
  assert_eq "$(cat "$data/machines/mac/config/dot_x")" ours
}

test_save_refuses_plaintext_secrets_and_wrong_branch() {
  data_checkout
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  local cfg="$data/machines/mac/config"
  printf 'x\n' >"$cfg/encrypted_private_dot_netrc.age"
  printf 'plain\n' >"$cfg/private_dot_netrc"
  run_envmgr save --yes
  assert_eq "$rc" 1 "$out"
  assert_contains "$out" "plaintext copy of an encrypted target"
  rm "$cfg/private_dot_netrc"

  printf 'AGE-SECRET-KEY-1ABC\n' >"$cfg/dot_keyfile"
  run_envmgr save --yes
  assert_eq "$rc" 1 "$out"
  assert_contains "$out" "looks like a secret"
  rm "$cfg/dot_keyfile"
  mkdir -p "$cfg/private_dot_ssh"
  printf 'k\n' >"$cfg/private_dot_ssh/id_ed25519"
  run_envmgr save --yes
  assert_eq "$rc" 1 "$out"
  assert_contains "$out" "looks like a secret"
  rm -r "$cfg/private_dot_ssh"
  assert_eq "$(git -C "$data" rev-list --count origin/main..HEAD)" 0

  git -C "$data" checkout -q -b feature
  run_envmgr save --yes
  assert_eq "$rc" 1 "$out"
  assert_contains "$out" "on branch feature, expected main"
  run_envmgr save --bogus
  assert_eq "$rc" 2 "$out"
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
      export work
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

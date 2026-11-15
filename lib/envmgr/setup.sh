#!/usr/bin/env bash
# envmgr setup: interactive, idempotent first-run walkthrough. Must run under
# /bin/bash 3.2 on a fresh Mac before Homebrew exists.

ENVMGR_DEFAULT_DATA_URL="git@github.com:juyanith/envmgr-data.git"
ENVMGR_DEFAULT_DATA_PATH="~/Work/Git/envmgr-data"
ENVMGR_SSH_KEY_URL="https://github.com/settings/ssh/new"

# Prompts read from file descriptor 3, opened on the terminal (or on
# $ENVMGR_TTY, which tests use to script the answers).
envmgr_setup_open_tty() {
  local tty="${ENVMGR_TTY:-/dev/tty}"

  { exec 3<"$tty"; } 2>/dev/null || \
    envmgr_die 1 "envmgr setup is interactive and needs a terminal"
  ENVMGR_PROMPT_FD=3
}

# Ask a question with an optional default; prints the answer.
envmgr_ask() {
  local prompt="$1"
  local default="${2:-}"
  local reply=""

  if [[ -n "$default" ]]; then
    printf '%s [%s]: ' "$prompt" "$default" >&2
  else
    printf '%s: ' "$prompt" >&2
  fi
  read -r reply <&3 || reply=""
  printf '%s\n' "${reply:-$default}"
}

envmgr_ask_yes() {
  local reply=""

  reply="$(envmgr_ask "$1 [y/N]")"
  [[ "$reply" == [Yy] || "$reply" == [Yy][Ee][Ss] ]]
}

# Like envmgr_ask_yes, but a blank answer means yes.
envmgr_ask_no() {
  local reply=""

  reply="$(envmgr_ask "$1 [Y/n]")"
  [[ "$reply" != [Nn] && "$reply" != [Nn][Oo] ]]
}

envmgr_setup_step() {
  printf '\n== %s\n' "$1"
}

envmgr_setup_open_url() {
  if command -v open >/dev/null 2>&1; then
    open "$1" >/dev/null 2>&1 || true
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$1" >/dev/null 2>&1 || true
  fi
}

# Make a Homebrew installed during this run usable for the rest of it.
envmgr_setup_brew_path() {
  envmgr_brew_find || return 1
  case ":$PATH:" in
    *":$(dirname -- "$ENVMGR_BREW"):"*) ;;
    *) PATH="$(dirname -- "$ENVMGR_BREW"):$PATH" ;;
  esac
  export PATH
}

# Ask for the administrator password once, and keep sudo's timestamp fresh
# until setup exits, so long installs never stop at a hidden prompt. The
# Homebrew installer runs non-interactively and fails when sudo would ask.
envmgr_setup_sudo() {
  [[ -z "${ENVMGR_SUDO_KEEPALIVE:-}" ]] || return 0
  printf 'Installing Homebrew needs administrator access; enter your password if asked.\n'
  sudo -v || envmgr_die 1 "administrator access is required to install Homebrew"
  (
    while kill -0 "$$" 2>/dev/null; do
      sudo -n true 2>/dev/null || true
      sleep 50
    done
  ) >/dev/null 2>&1 &
  ENVMGR_SUDO_KEEPALIVE=$!
}

envmgr_setup_brew_install() {
  local rc=0

  if ! envmgr_setup_brew_path; then
    envmgr_setup_sudo
    printf 'Installing Homebrew.\n'
    envmgr_pkg_homebrew_bootstrap || rc=$?
    case "$rc" in
      0) envmgr_setup_brew_path || return 1 ;;
      "$ENVMGR_EXIT_REBOOT") exit "$ENVMGR_EXIT_REBOOT" ;;
      *) return 1 ;;
    esac
  fi
  envmgr_brew install "$@"
}

envmgr_setup_prerequisites() {
  local missing=()
  local tool=""
  local link="$HOME/.local/bin/envmgr"
  local target="$ENVMGR_ROOT/bin/envmgr"

  envmgr_setup_step "Prerequisites"
  if [[ "$ENVMGR_OS" == darwin ]] && ! xcode-select -p >/dev/null 2>&1; then
    xcode-select --install >/dev/null 2>&1 || true
    printf 'Installing the Command Line Tools. Finish the dialog that macOS opened;\n'
    printf 'setup continues by itself once they are installed (Ctrl-C stops).\n'
    until xcode-select -p >/dev/null 2>&1; do
      sleep "${ENVMGR_POLL_SECONDS:-5}"
    done
    printf 'The Command Line Tools are installed.\n'
  fi
  for tool in git chezmoi; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  if ((${#missing[@]} == 0)); then
    printf 'Git and Chezmoi are installed.\n'
  else
    printf 'Installing %s.\n' "${missing[*]}"
    case "$ENVMGR_DISTRIBUTION" in
      omarchy) omarchy pkg add "${missing[@]}" ;;
      macos|fedora-cosmic-atomic) envmgr_setup_brew_install "${missing[@]}" ;;
      *) envmgr_die 1 "install ${missing[*]} manually, then rerun envmgr setup" ;;
    esac || envmgr_die 1 "could not install ${missing[*]}"
  fi

  if [[ -L "$link" && "$(readlink -- "$link")" == "$target" ]]; then
    printf 'Verified %s.\n' "$(envmgr_display_path "$link")"
  else
    if [[ -e "$link" || -L "$link" ]]; then
      envmgr_backup_file "$link" setup
      rm -f -- "$link"
    fi
    mkdir -p -- "$(dirname -- "$link")"
    ln -s -- "$target" "$link"
    printf 'Linked %s -> %s.\n' "$(envmgr_display_path "$link")" "$(envmgr_display_path "$target")"
  fi
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) printf 'Add ~/.local/bin to PATH to run envmgr by name.\n' ;;
  esac
}

envmgr_is_ssh_url() {
  case "$1" in
    ssh://*|*@*:*) return 0 ;;
    *) return 1 ;;
  esac
}

envmgr_github_ssh_ok() {
  local output=""

  # GitHub exits 1 even when authentication succeeds.
  output="$(ssh -T -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
    git@github.com 2>&1 </dev/null)" || true
  [[ "$output" == *"successfully authenticated"* ]]
}

envmgr_setup_ssh() {
  local url="$1"
  local key="$HOME/.ssh/id_ed25519"

  envmgr_setup_step "SSH"
  if ! envmgr_is_ssh_url "$url"; then
    printf 'The data repository URL does not use SSH; skipping.\n'
    return 0
  fi
  case "$url" in
    *github.com*) ;;
    *)
      printf 'Make sure this machine can reach %s over SSH.\n' "$url"
      return 0
      ;;
  esac
  if envmgr_github_ssh_ok; then
    printf 'GitHub accepts this machine'\''s SSH key.\n'
    return 0
  fi
  if [[ ! -f "$key.pub" ]]; then
    printf 'Creating %s. Choose a passphrase when asked.\n' "$(envmgr_display_path "$key")"
    mkdir -p -- "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    ssh-keygen -t ed25519 -C "$(id -un)@$(hostname -s 2>/dev/null || hostname)" -f "$key" <&3 || \
      envmgr_die 1 "ssh-keygen failed"
  fi
  while ! envmgr_github_ssh_ok; do
    printf '\nAdd this public key to GitHub at %s:\n\n' "$ENVMGR_SSH_KEY_URL"
    cat -- "$key.pub"
    printf '\n'
    envmgr_setup_open_url "$ENVMGR_SSH_KEY_URL"
    if ! envmgr_ask_yes "Press y after adding the key to check again (n stops setup)"; then
      envmgr_die 1 "GitHub does not accept this machine's SSH key yet; rerun envmgr setup"
    fi
  done
  printf 'GitHub accepts this machine'\''s SSH key.\n'
}

envmgr_setup_data() {
  local config=""
  local data=""
  local url=""
  local path=""

  config="$(envmgr_local_config_file)"
  envmgr_setup_step "Data repository"
  if data="$(envmgr_local_get data)" && [[ -d "$data/machines" ]]; then
    printf 'Using %s.\n' "$(envmgr_display_path "$data")"
    return 0
  fi

  url="$(envmgr_kv_get "$config" data_url 2>/dev/null || true)"
  url="$(envmgr_ask "Data repository URL" "${url:-$ENVMGR_DEFAULT_DATA_URL}")"
  path="$(envmgr_ask "Checkout path" "$ENVMGR_DEFAULT_DATA_PATH")"
  envmgr_setup_ssh "$url"
  data="$(envmgr_expand_path "$path")"

  if [[ -d "$data/.git" ]]; then
    printf 'Using existing checkout %s.\n' "$(envmgr_display_path "$data")"
  elif [[ -e "$data" ]]; then
    envmgr_die 1 "$path exists and is not a Git checkout"
  else
    mkdir -p -- "$(dirname -- "$data")"
    git clone -- "$url" "$data" || envmgr_die 1 "could not clone $url"
  fi
  [[ -d "$data/machines" ]] || envmgr_die 1 "data repository has no machines/ directory: $path"
  envmgr_kv_set "$config" data "$path"
  envmgr_kv_set "$config" data_url "$url"
}

# Print the machines whose os and distribution match this system.
envmgr_matching_machines() {
  local data="$1"
  local dir=""

  for dir in "$data"/machines/*/; do
    [[ -f "$dir/machine.conf" ]] || continue
    [[ "$(envmgr_kv_get "$dir/machine.conf" os 2>/dev/null)" == "$ENVMGR_OS" ]] || continue
    [[ "$(envmgr_kv_get "$dir/machine.conf" distribution 2>/dev/null)" == "$ENVMGR_DISTRIBUTION" ]] || continue
    basename -- "$dir"
  done
}

# Print Chezmoi's current source directory when it exists and lies outside
# the data repository, for example a legacy envmgr checkout.
envmgr_foreign_chezmoi_source() {
  local data="$1"
  local source=""
  local real_source=""
  local real_data=""

  command -v chezmoi >/dev/null 2>&1 || return 0
  source="$(chezmoi source-path 2>/dev/null)" || return 0
  [[ -n "$source" && -d "$source" ]] || return 0
  real_source="$(cd -P -- "$source" && pwd)" || return 0
  real_data="$(cd -P -- "$data" && pwd)" || return 0
  case "$real_source/" in
    "$real_data"/machines/*) ;;
    *) envmgr_display_path "$source" ;;
  esac
}

# Ask for a new machine ID, suggesting one from the host name. Prompts and
# messages go to stderr, because the caller captures the ID.
envmgr_setup_new_id() {
  local data="$1"
  local suggested=""
  local id=""

  suggested="$( (hostname -s 2>/dev/null || hostname) | tr '[:upper:]' '[:lower:]' | \
    sed 's/[^a-z0-9._-]/-/g; s/^[^a-z0-9]*//')"
  if ! envmgr_valid_machine_id "$suggested" || [[ -e "$data/machines/$suggested" ]]; then
    suggested=""
  fi
  while true; do
    id="$(envmgr_ask "New machine ID" "$suggested")"
    if ! envmgr_valid_machine_id "$id"; then
      printf 'Use letters, digits, dots, dashes, and underscores.\n' >&2
    elif [[ -e "$data/machines/$id" ]]; then
      printf 'Machine %s already exists; choose it from the list, or pick another ID.\n' "$id" >&2
    else
      printf '%s\n' "$id"
      return 0
    fi
  done
}

# Ask which matching machine a new one copies, suggesting the one changed
# most recently. Prints nothing for an empty machine.
envmgr_setup_copy_from() {
  local data="$1"
  local machine=""
  local from=""
  local suggested=""
  local time=0
  local latest=-1

  shift
  for machine in "$@"; do
    time="$(git -C "$data" log -1 --format=%ct -- "machines/$machine" 2>/dev/null)" || time=0
    if ((${time:-0} > latest)); then
      latest="${time:-0}"
      suggested="$machine"
    fi
  done
  while true; do
    from="$(envmgr_ask "Copy from (none for an empty machine)" "$suggested")"
    case "$from" in
      ""|none) return 0 ;;
    esac
    for machine in "$@"; do
      if [[ "$from" == "$machine" ]]; then
        printf '%s\n' "$from"
        return 0
      fi
    done
    printf 'Enter one of: %s, or none.\n' "$*" >&2
  done
}

# Selecting a machine switches Chezmoi to it; confirm when that would leave
# another source behind.
envmgr_setup_confirm_switch() {
  local foreign="$1"
  local machine="$2"

  [[ -z "$foreign" ]] && return 0
  envmgr_ask_yes "Switch Chezmoi from $foreign to machine $machine?" && return 0
  printf 'Chezmoi still uses %s.\n' "$foreign"
  return 1
}

envmgr_setup_machine() {
  local data=""
  local machine=""
  local choice=""
  local from=""
  local description=""
  local foreign=""
  local machines=()
  local i=0

  envmgr_setup_step "Machine"
  data="$(envmgr_data_dir)"
  if machine="$(envmgr_kv_get "$(envmgr_local_config_file)" machine 2>/dev/null)" && \
    [[ -d "$data/machines/$machine" ]]; then
    printf 'This machine is %s.\n' "$machine"
    return 0
  fi

  while IFS= read -r machine; do
    machines+=("$machine")
  done < <(envmgr_matching_machines "$data")
  printf 'Machines for %s:\n' "$ENVMGR_DISTRIBUTION"
  for ((i = 0; i < ${#machines[@]}; i++)); do
    printf '  %d) %s  %s\n' "$((i + 1))" "${machines[$i]}" \
      "$(envmgr_kv_get "$data/machines/${machines[$i]}/machine.conf" description 2>/dev/null || true)"
  done
  printf '  n) new machine\n  s) skip for now\n'
  foreign="$(envmgr_foreign_chezmoi_source "$data")"
  if [[ -n "$foreign" ]]; then
    printf '\nChezmoi currently uses %s. Choosing a machine switches it to\n' "$foreign"
    printf 'that machine'\''s files, and the next restore overwrites targets that differ.\n'
    printf 'If you are migrating from the legacy envmgr, choose s, then run\n'
    printf 'legacy-export.sh and envmgr init <machine-id>.\n'
  fi

  while true; do
    choice="$(envmgr_ask "Choose")"
    case "$choice" in
      s|S)
        printf 'Skipped. Run envmgr init <machine-id> later.\n'
        return 0
        ;;
      n|N)
        machine="$(envmgr_setup_new_id "$data")"
        from=""
        if ((${#machines[@]})); then
          from="$(envmgr_setup_copy_from "$data" "${machines[@]}")"
        fi
        description="$(envmgr_ask "Description (for example, Mac mini in the office)")"
        envmgr_setup_confirm_switch "$foreign" "$machine" || continue
        if [[ -n "$from" ]]; then
          envmgr_cmd_init --new --from "$from" "$machine"
        else
          envmgr_cmd_init --new "$machine"
        fi
        [[ -z "$description" ]] || \
          envmgr_kv_set "$data/machines/$machine/machine.conf" description "$description"
        return 0
        ;;
      *[!0-9]*|"") ;;
      *)
        if ((choice >= 1 && choice <= ${#machines[@]})); then
          machine="${machines[$((choice - 1))]}"
          envmgr_setup_confirm_switch "$foreign" "$machine" || continue
          envmgr_cmd_init "$machine"
          return 0
        fi
        ;;
    esac
    printf 'Enter a number, n, or s.\n'
  done
}

envmgr_setup_agent() {
  local config=""
  local agent=""

  config="$(envmgr_local_config_file)"
  envmgr_setup_step "Agent"
  if agent="$(envmgr_kv_get "$config" agent 2>/dev/null)"; then
    printf 'Agent for envmgr evaluate: %s\n' "${agent:-none}"
    return 0
  fi
  agent="$(envmgr_ask "Agent command for envmgr evaluate (for example codex or claude; blank for none)")"
  envmgr_kv_set "$config" agent "$agent"
}

# Read one line from setup's input without echoing it. Comment lines are
# skipped, so pasting a whole age key file works as well as pasting its key.
envmgr_setup_read_secret() {
  local line=""

  printf '%s: ' "$1" >&2
  while read -r -s line <&3; do
    [[ "$line" == \#* ]] || break
  done
  printf '\n' >&2
  printf '%s\n' "$line"
}

# Check that an age identity file decrypts an encrypted source.
envmgr_setup_key_decrypts() {
  local key="$1"
  local file="$2"
  local config=""
  local rc=0

  config="$(mktemp "${TMPDIR:-/tmp}/envmgr-age.XXXXXX")"
  printf 'encryption = "age"\n[age]\n  identity = "%s"\n' "$key" >"$config"
  chezmoi --config "$config" --config-format toml decrypt "$file" >/dev/null 2>&1 || rc=1
  rm -f -- "$config"
  return "$rc"
}

# The age key is copied or pasted, never generated here: a new key could not
# decrypt files that another machine encrypted.
envmgr_setup_age_key() {
  local data=""
  local machine=""
  local config=""
  local encrypted=""
  local key=""
  local file=""
  local tmp=""

  machine="$(envmgr_kv_get "$(envmgr_local_config_file)" machine 2>/dev/null)" || return 0
  data="$(envmgr_data_dir)"
  config="$data/machines/$machine/config"
  [[ -d "$config" ]] || return 0
  encrypted="$(find "$config" -name 'encrypted_*' -type f -print | head -n 1)"
  [[ -n "$encrypted" ]] || return 0
  envmgr_setup_step "Age key"
  file="$(envmgr_age_key_file)"
  if [[ -r "$file" ]]; then
    printf 'The age key for encrypted files is present.\n'
    return 0
  fi
  printf 'Machine %s has encrypted files, which need the age key from another\n' "$machine"
  printf 'machine or your backup. Paste it here (the AGE-SECRET-KEY- line, or the\n'
  printf 'whole file), or press Enter to copy it to %s later.\n' "$(envmgr_display_path "$file")"
  mkdir -p -- "$(dirname -- "$file")"
  tmp="$file.new"
  while true; do
    key="$(envmgr_setup_read_secret "Age key")"
    if [[ -z "$key" ]]; then
      printf 'Before envmgr restore, copy the key to %s, readable only by you (chmod 600).\n' \
        "$(envmgr_display_path "$file")"
      return 0
    fi
    if [[ "$key" =~ ^AGE-SECRET-KEY-[0-9A-Z-]+$ ]]; then
      (umask 077 && printf '%s\n' "$key" >"$tmp")
      if envmgr_setup_key_decrypts "$tmp" "$encrypted"; then
        mv -f -- "$tmp" "$file"
        chmod 600 "$file"
        printf 'Saved the age key to %s. Back it up if you have not already.\n' \
          "$(envmgr_display_path "$file")"
        return 0
      fi
      rm -f -- "$tmp"
      printf 'That key does not decrypt %s; paste the key this machine'\''s files use.\n' \
        "$(envmgr_display_path "$encrypted")"
    else
      printf 'That is not an age secret key; it starts with AGE-SECRET-KEY-.\n'
    fi
  done
}

# Commit and push a machine that setup created or changed, so it is on origin
# even if restore later stops for a reboot.
# Exit 0 when any of the machine's providers declares the package.
envmgr_setup_declares() {
  local machine_dir="$1"
  local name="$2"
  local provider=""
  local names=""

  for provider in $(envmgr_active_providers "$machine_dir"); do
    envmgr_pkg_enter "$machine_dir" "$provider"
    names="$(envmgr_pkg_call "$provider" list | awk '{ print $1 }')" || return 1
    printf '%s\n' "$names" | grep -Fxq -- "$name" && return 0
  done
  return 1
}

# Declare Git and Chezmoi, which envmgr needs, with the provider setup
# installs them through, so restore keeps them installed and upgraded.
envmgr_setup_tools() {
  local machine=""
  local machine_dir=""
  local provider=""
  local tool=""
  local started=false
  local created=false

  machine="$(envmgr_kv_get "$(envmgr_local_config_file)" machine 2>/dev/null)" || return 0
  machine_dir="$(envmgr_machine_dir "$(envmgr_data_dir)" "$machine")"
  case "$ENVMGR_DISTRIBUTION" in
    macos|fedora-cosmic-atomic) provider=homebrew ;;
    omarchy) provider=omarchy ;;
    *) return 0 ;;
  esac
  envmgr_pkg_call "$provider" available || return 0
  [[ -d "$machine_dir/packages/$provider" ]] || created=true
  for tool in git chezmoi; do
    envmgr_setup_declares "$machine_dir" "$tool" && continue
    if [[ "$started" == false ]]; then
      envmgr_setup_step "Tools"
      started=true
    fi
    # A tool the system provides (for example, Git from the Command Line
    # Tools or the Fedora image) is updated with the system, not declared.
    (envmgr_adopt_package "$machine_dir" "$provider" "$tool" 2>/dev/null) || \
      printf '%s is not installed with %s; leaving it undeclared.\n' "$tool" "$provider"
  done
  # Adopting creates the provider directory; remove it if nothing was added.
  if [[ "$created" == true ]]; then
    rmdir -- "$machine_dir/packages/$provider" 2>/dev/null || true
  fi
}

envmgr_setup_save() {
  local machine=""
  local data=""

  machine="$(envmgr_kv_get "$(envmgr_local_config_file)" machine 2>/dev/null)" || return 0
  data="$(envmgr_data_dir)"
  [[ -e "$data/.git" ]] || return 0
  [[ -n "$(git -C "$data" status --porcelain -- "machines/$machine")" ]] || return 0
  envmgr_setup_step "Save"
  printf 'Machine %s has changes that are not in the data repository yet.\n' "$machine"
  if ! envmgr_ask_no "Commit and push them now?"; then
    printf 'Not saved. Run envmgr save when you are ready.\n'
    return 0
  fi
  # A failed save (for example, no push access yet) does not stop setup.
  (envmgr_cmd_save --yes) || \
    envmgr_warn "machine $machine was not saved; run envmgr save once the problem is fixed"
}

# Run envmgr restore. A reboot or a failure ends setup; running setup again
# skips the finished steps and continues here.
envmgr_setup_restore() {
  local machine=""
  local rc=0

  machine="$(envmgr_kv_get "$(envmgr_local_config_file)" machine 2>/dev/null)" || return 0
  envmgr_setup_step "Restore"
  # After the git provider pulled new code, restore restarts setup; the
  # user already chose to restore.
  if [[ -z "${ENVMGR_REEXECUTED:-}" ]]; then
    printf 'Restore installs packages, applies config, then runs system units,\n'
    printf 'showing what will change before each.\n'
    if ! envmgr_ask_no "Restore $machine now?"; then
      printf 'Skipped. Run envmgr restore when you are ready.\n'
      return 0
    fi
  fi
  envmgr_cmd_restore || rc=$?
  case "$rc" in
    0) ;;
    "$ENVMGR_EXIT_REBOOT")
      printf '\nReboot or log out and back in, then run envmgr setup again to continue.\n'
      exit "$ENVMGR_EXIT_REBOOT"
      ;;
    *)
      printf '\nRestore stopped. Fix the problem above, then run envmgr setup again to continue.\n'
      exit 1
      ;;
  esac
}

# Print the machine's manual steps, the ones envmgr cannot automate.
envmgr_setup_postinstall() {
  local machine=""
  local file=""

  machine="$(envmgr_kv_get "$(envmgr_local_config_file)" machine 2>/dev/null)" || return 0
  file="$(envmgr_data_dir)/machines/$machine/POSTINSTALL.md"
  [[ -f "$file" ]] || return 0
  envmgr_setup_step "Manual steps"
  cat -- "$file"
}

envmgr_cmd_setup() {
  [[ $# -eq 0 ]] || envmgr_usage_error "setup takes no arguments"
  envmgr_detect_platform
  envmgr_setup_open_tty
  envmgr_setup_prerequisites
  envmgr_setup_data
  envmgr_setup_machine
  envmgr_setup_age_key
  envmgr_setup_agent
  envmgr_setup_tools
  envmgr_setup_save
  envmgr_setup_restore
  envmgr_setup_postinstall
  exec 3<&-
  printf '\nSetup is complete.\n'
}

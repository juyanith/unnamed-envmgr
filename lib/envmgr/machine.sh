#!/usr/bin/env bash
# Machine selection and machine.conf metadata.

envmgr_valid_machine_id() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

envmgr_active_machine() {
  envmgr_local_get machine || \
    envmgr_die 1 "no machine is selected; run 'envmgr setup' or 'envmgr init <machine-id>'"
}

envmgr_machine_dir() {
  local data="$1"
  local machine="$2"

  printf '%s\n' "$data/machines/$machine"
}

# Compare machine.conf with the running system.
# mode "refuse" exits on mismatch; mode "warn" reports and continues.
envmgr_verify_machine() {
  local machine_dir="$1"
  local mode="$2"
  local conf="$machine_dir/machine.conf"
  local key=""
  local expected=""
  local actual=""
  local mismatch=false

  [[ -r "$conf" ]] || envmgr_die 1 "missing machine metadata: $conf"
  envmgr_detect_platform

  for key in os distribution; do
    expected="$(envmgr_kv_get "$conf" "$key")" || \
      envmgr_die 1 "$conf does not define required key '$key'"
    case "$key" in
      os) actual="$ENVMGR_OS" ;;
      distribution) actual="$ENVMGR_DISTRIBUTION" ;;
    esac
    if [[ "$expected" != "$actual" ]]; then
      mismatch=true
      if [[ "$mode" == "refuse" ]]; then
        envmgr_die 1 "machine $(basename -- "$machine_dir") expects $key=$expected, but this system is $key=$actual"
      fi
      envmgr_warn "machine $(basename -- "$machine_dir") expects $key=$expected, but this system is $key=$actual"
    fi
  done

  if expected="$(envmgr_kv_get "$conf" architecture)" && \
    [[ "$expected" != "$ENVMGR_ARCHITECTURE" ]]; then
    envmgr_warn "machine $(basename -- "$machine_dir") expects architecture=$expected, but this system is $ENVMGR_ARCHITECTURE"
  fi

  [[ "$mismatch" == false ]]
}

# Resolve the active machine and verify it. Prints the machine directory.
envmgr_active_machine_dir() {
  local mode="$1"
  local data=""
  local machine=""
  local machine_dir=""

  data="$(envmgr_data_dir)"
  machine="$(envmgr_active_machine)"
  machine_dir="$(envmgr_machine_dir "$data" "$machine")"
  [[ -d "$machine_dir" ]] || envmgr_die 1 "selected machine does not exist: $machine_dir"
  envmgr_verify_machine "$machine_dir" "$mode" || true
  printf '%s\n' "$machine_dir"
}

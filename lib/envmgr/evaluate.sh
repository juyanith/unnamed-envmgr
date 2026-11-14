#!/usr/bin/env bash
# envmgr evaluate: start the configured agent on the active machine.

# Print the agent's initial prompt. The check report holds paths and
# statuses only, never target contents.
envmgr_evaluate_prompt() {
  local machine="$1"
  local scope="$2"
  local report="$3"
  local status="$4"

  cat <<EOF
You are helping maintain the envmgr machine "$machine". The current
directory is the envmgr data repository.

Read these first:
- machines/$machine/machine.conf (machine metadata)
- machines/$machine/SPEC.md (what this machine should have)
- AGENTS.md (configuration rules for this repository), if present
- $ENVMGR_ROOT/DESIGN.md (how envmgr works: config, packages, system units)

Current state from \`$scope\` (exit $status: 0 in sync, 3 drift, 1 error):

$report

Evaluate whether the machine's files under machines/$machine/ match its
SPEC.md and explain any drift above. Propose changes, and make the ones the
user approves.

Boundaries:
- You may edit files under machines/$machine/ and the repository's
  documentation.
- Do not run envmgr restore, install or remove packages, or change files
  outside this repository.
- Do not decrypt encrypted_ files or read the age key.
- Do not commit or push. When you are done, summarize the changes so the user
  can review them, run envmgr restore, and commit.
EOF
}

envmgr_cmd_evaluate() {
  local category=""
  local offline=false
  local agent=""
  local data=""
  local machine=""
  local report=""
  local status=0
  local check_args=()
  local command=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --offline) offline=true ;;
      -*) envmgr_usage_error "unknown option for evaluate: $1" ;;
      *)
        [[ -z "$category" ]] || envmgr_usage_error "evaluate takes one category"
        category="$(envmgr_parse_category "$1")"
        ;;
    esac
    shift
  done

  agent="$(envmgr_kv_get "$(envmgr_local_config_file)" agent 2>/dev/null)" || agent=""
  [[ -n "$agent" ]] || \
    envmgr_die 1 "no agent is configured; add agent=<command> (for example, agent=claude) to $(envmgr_display_path "$(envmgr_local_config_file)")"
  # The command is split on whitespace; quotes are not interpreted.
  read -r -a command <<<"$agent"
  command -v "${command[0]}" >/dev/null 2>&1 || envmgr_die 1 "agent command not found: ${command[0]}"

  data="$(envmgr_data_dir)"
  machine="$(envmgr_active_machine)"
  [[ -d "$(envmgr_machine_dir "$data" "$machine")" ]] || \
    envmgr_die 1 "selected machine does not exist: $machine"

  [[ -n "$category" ]] && check_args+=("$category")
  [[ "$offline" == true ]] && check_args+=(--offline)
  printf 'Checking %s.\n' "$machine"
  report="$(envmgr_cmd_check ${check_args[@]+"${check_args[@]}"} 2>&1)" || status=$?
  printf '%s\n' "$report"

  printf '\nStarting %s in %s.\n' "$agent" "$(envmgr_display_path "$data")"
  cd -- "$data" || return 1
  exec "${command[@]}" "$(envmgr_evaluate_prompt "$machine" \
    "envmgr check${category:+ $category}" "$report" "$status")"
}

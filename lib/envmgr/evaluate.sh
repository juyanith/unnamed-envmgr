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

# Fast-forward the data checkout when it is clean, so the comparison sees
# the latest files from other machines. Otherwise warn and use what is there.
envmgr_evaluate_update_data() {
  local data="$1"
  local machine_dir="$2"
  local branch=""
  local blocker=""

  [[ -e "$data/.git" ]] || return 0
  branch="$(envmgr_data_branch "$data" "$machine_dir")"
  if ! git -C "$data" fetch --quiet origin "$branch"; then
    envmgr_warn "could not fetch the data repository; comparing the files already there"
    return 0
  fi
  git -C "$data" rev-parse --verify --quiet "origin/$branch" >/dev/null || return 0
  blocker="$(envmgr_git_blocker "$data" "$branch")"
  if [[ -n "$blocker" ]]; then
    envmgr_warn "not updating the data checkout ($blocker); comparing the files already there"
    return 0
  fi
  git -C "$data" merge --ff-only --quiet "origin/$branch" || \
    envmgr_warn "could not fast-forward the data checkout; comparing the files already there"
}

# Print "target<TAB>source" for each file or symlink a machine manages, with
# sources as machines/<id>/config/... paths.
envmgr_evaluate_sources() {
  local machine_dir="$1"
  local id=""
  local managed=""
  local sources=""
  local target=""
  local absolute=()

  id="$(basename -- "$machine_dir")"
  [[ -d "$machine_dir/config" ]] || return 0
  managed="$(envmgr_chezmoi "$machine_dir" managed --include files,symlinks \
    --path-style relative)" || return 1
  [[ -n "$managed" ]] || return 0
  while IFS= read -r target; do
    absolute+=("$HOME/$target")
  done <<<"$managed"
  sources="$(envmgr_chezmoi "$machine_dir" source-path "${absolute[@]}")" || return 1
  paste <(printf '%s\n' "$managed") \
    <(printf '%s\n' "$sources" | sed "s|^.*/machines/$id/config/|machines/$id/config/|")
}

# Compare two machines' config sources by target. Prints each target that is
# managed on one side only, or whose sources differ in name or content, with
# the source on each side. Remaining arguments are paths relative to $HOME
# that limit the comparison to targets at or under them.
envmgr_evaluate_compare() {
  local data="$1"
  local from_dir="$2"
  local machine_dir="$3"
  local there=""
  local here=""
  local state=""
  local target=""
  local source_there=""
  local source_here=""
  local tab=$'\t'
  local rc=0

  shift 3
  there="$(mktemp "${TMPDIR:-/tmp}/envmgr-there.XXXXXX")"
  here="$(mktemp "${TMPDIR:-/tmp}/envmgr-here.XXXXXX")"
  envmgr_evaluate_sources "$from_dir" >"$there" || rc=1
  envmgr_evaluate_sources "$machine_dir" >"$here" || rc=1
  if [[ "$rc" -ne 0 ]]; then
    rm -f -- "$there" "$here"
    return 1
  fi

  while IFS="$tab" read -r state target source_there source_here; do
    case "$state" in
      both)
        # Same content under the same source name: nothing to do.
        if [[ "${source_there#*/config/}" == "${source_here#*/config/}" ]] && \
          cmp -s -- "$data/$source_there" "$data/$source_here"; then
          continue
        fi
        printf 'different   %s\n    there: %s\n    here:  %s\n' \
          "$target" "$source_there" "$source_here"
        ;;
      there) printf 'only there  %s\n    there: %s\n' "$target" "$source_there" ;;
      here) printf 'only here   %s\n    here:  %s\n' "$target" "$source_here" ;;
    esac
  done < <(
    # Filters are joined with the unit separator, because awk -v values
    # cannot hold newlines.
    awk -F "$tab" -v filters="$(IFS=$'\037'; printf '%s' "$*")" '
      BEGIN { n = filters == "" ? 0 : split(filters, filter, "\037") }
      function wanted(t,   i) {
        if (n == 0) return 1
        for (i = 1; i <= n; i++)
          if (t == filter[i] || index(t, filter[i] "/") == 1) return 1
        return 0
      }
      FNR == NR { if (wanted($1)) there[$1] = $2; next }
      wanted($1) { here[$1] = $2 }
      END {
        for (t in there)
          print (t in here ? "both" : "there") "\t" t "\t" there[t] "\t" (t in here ? here[t] : "")
        for (t in here)
          if (!(t in there)) print "here\t" t "\t-\t" here[t]
      }
    ' "$there" "$here" | sort -t "$tab" -k2,2
  )
  rm -f -- "$there" "$here"
}

# Print the agent's initial prompt for evaluate --from.
envmgr_evaluate_from_prompt() {
  local machine="$1"
  local from="$2"
  local comparison="$3"
  local age_key="$4"

  cat <<EOF
You are helping copy configuration from the envmgr machine "$from" to the
machine "$machine", which is this machine. The current directory is the
envmgr data repository.

Read these first:
- machines/$machine/machine.conf and machines/$from/machine.conf (if the OS
  or distribution differs, check that each file makes sense on this machine)
- machines/$machine/SPEC.md (what this machine should have), if present
- AGENTS.md (configuration rules for this repository), if present
- $ENVMGR_ROOT/DESIGN.md (how envmgr works; see Configuration)

Config sources compared by target (paths only, never contents):

$comparison

- only there: managed on $from only; a candidate to copy.
- different: managed on both machines, with sources that differ in name or
  content; a candidate to merge or replace. Compare the two sources and,
  where it helps, the target file on this machine.
- only here: managed on this machine only. It is listed for context; propose
  removing it only if the user asks.

The age key (~/.config/envmgr/age.key) is $age_key on this machine.

Propose which files to copy, merge, or replace, and make the changes the user
approves.

Boundaries:
- You may read anything under machines/$from/, but edit only files under
  machines/$machine/ and the repository's documentation.
- Keep source names, including prefixes such as dot_, private_, executable_,
  exact_, modify_, and encrypted_, so attributes carry over. A template may
  reference only files inside its own config/ directory; copy those too.
- Copy encrypted_ sources byte for byte. Do not decrypt them or read the age
  key. If the key is missing, tell the user to copy it from another machine.
- You may read existing target files under ~ to merge them, but not files
  that look like secrets (keys, tokens, credentials, .netrc).
- Do not run envmgr restore, install or remove packages, change files outside
  this repository, or commit or push.
- When you are done, summarize the changes and tell the user to run
  envmgr restore config --dry-run, then envmgr restore config, then
  envmgr save.
EOF
}

envmgr_evaluate_from() {
  local agent="$1"
  local from="$2"
  local offline="$3"
  local data=""
  local machine=""
  local machine_dir=""
  local from_dir=""
  local comparison=""
  local age_key=missing
  local target=""
  local filters=()

  shift 3
  data="$(envmgr_data_dir)"
  machine="$(envmgr_active_machine)"
  machine_dir="$(envmgr_machine_dir "$data" "$machine")"
  [[ -d "$machine_dir" ]] || envmgr_die 1 "selected machine does not exist: $machine"
  [[ "$from" != "$machine" ]] || \
    envmgr_usage_error "--from names the selected machine; give another machine ID"
  [[ "$offline" == true ]] || envmgr_evaluate_update_data "$data" "$machine_dir"
  from_dir="$(envmgr_machine_dir "$data" "$from")"
  [[ -d "$from_dir" ]] || envmgr_die 1 "machine does not exist: $from"
  for target in "$@"; do
    filters+=("${target#"$HOME"/}")
  done

  comparison="$(envmgr_evaluate_compare "$data" "$from_dir" "$machine_dir" \
    ${filters[@]+"${filters[@]}"})" || return 1
  printf 'Comparing config from %s with %s.\n' "$from" "$machine"
  [[ -z "$comparison" ]] || printf '%s\n' "$comparison"
  if ! grep -Eq '^(only there|different) ' <<<"$comparison"; then
    printf 'evaluate: nothing to copy from %s\n' "$from"
    return 0
  fi
  [[ -f "$(envmgr_age_key_file)" ]] && age_key=present

  printf '\nStarting %s in %s.\n' "$agent" "$(envmgr_display_path "$data")"
  cd -- "$data" || return 1
  exec "${ENVMGR_AGENT_COMMAND[@]}" \
    "$(envmgr_evaluate_from_prompt "$machine" "$from" "$comparison" "$age_key")"
}

envmgr_cmd_evaluate() {
  local category=""
  local offline=false
  local from=""
  local agent=""
  local data=""
  local machine=""
  local report=""
  local status=0
  local i=0
  local positional=()
  local check_args=()
  local command=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --offline) offline=true ;;
      --from)
        [[ $# -ge 2 && -n "$2" ]] || envmgr_usage_error "--from requires a machine ID"
        envmgr_valid_machine_id "$2" || envmgr_usage_error "invalid machine ID: $2"
        from="$2"
        shift
        ;;
      -*) envmgr_usage_error "unknown option for evaluate: $1" ;;
      *) positional+=("$1") ;;
    esac
    shift
  done
  if [[ -n "$from" ]]; then
    # With --from, arguments are targets that narrow the comparison.
    for ((i = 0; i < ${#positional[@]}; i++)); do
      positional[i]="$(envmgr_absolute_target "${positional[i]}")"
    done
  elif ((${#positional[@]} > 1)); then
    envmgr_usage_error "evaluate takes one category"
  elif ((${#positional[@]} == 1)); then
    category="$(envmgr_parse_category "${positional[0]}")"
  fi

  agent="$(envmgr_kv_get "$(envmgr_local_config_file)" agent 2>/dev/null)" || agent=""
  [[ -n "$agent" ]] || \
    envmgr_die 1 "no agent is configured; add agent=<command> (for example, agent=claude) to $(envmgr_display_path "$(envmgr_local_config_file)")"
  # The command is split on whitespace; quotes are not interpreted.
  read -r -a command <<<"$agent"
  command -v "${command[0]}" >/dev/null 2>&1 || envmgr_die 1 "agent command not found: ${command[0]}"

  if [[ -n "$from" ]]; then
    ENVMGR_AGENT_COMMAND=("${command[@]}")
    envmgr_evaluate_from "$agent" "$from" "$offline" ${positional[@]+"${positional[@]}"}
    return
  fi

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

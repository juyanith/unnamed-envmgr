#!/usr/bin/env bash
# envmgr migrate: move the data repository, with its history, to a new remote.

envmgr_git_data() {
  git -C "$ENVMGR_MIGRATE_DATA" "$@"
}

# Refuse unless every local branch is pushed to origin and the tree is clean.
envmgr_migrate_require_pushed() {
  local branch=""
  local upstream=""
  local ahead=""

  [[ -z "$(envmgr_git_data status --porcelain)" ]] || \
    envmgr_die 1 "the data checkout has uncommitted changes; commit and push them first"
  while read -r branch upstream; do
    [[ -n "$upstream" && "$upstream" == origin/* ]] || \
      envmgr_die 1 "branch $branch does not track a branch on origin; push it there first"
    envmgr_git_data rev-parse --verify --quiet "$upstream" >/dev/null || \
      envmgr_die 1 "branch $branch tracks $upstream, which no longer exists"
    ahead="$(envmgr_git_data rev-list --count "$upstream..$branch")" || return 1
    [[ "$ahead" -eq 0 ]] || \
      envmgr_die 1 "branch $branch has $ahead unpushed commit(s); push them first"
  done < <(envmgr_git_data for-each-ref --format='%(refname:short) %(upstream:short)' refs/heads)
}

# Point git provider entries for the old URL at the new one. The edits are
# left uncommitted for review. Prints each changed manifest.
envmgr_migrate_manifests() {
  local old="$1"
  local new="$2"
  local repos=""
  local tmp=""

  for repos in "$ENVMGR_MIGRATE_DATA"/machines/*/packages/git/repos; do
    [[ -f "$repos" ]] || continue
    tmp="$(mktemp "$repos.XXXXXX")"
    awk -v old="$old" -v new="$new" '
      !/^[[:space:]]*(#|$)/ && $1 == old {
        i = index($0, old)
        $0 = substr($0, 1, i - 1) new substr($0, i + length(old))
      }
      { print }
    ' "$repos" >"$tmp"
    if cmp -s -- "$repos" "$tmp"; then
      rm -f -- "$tmp"
    else
      mv -f -- "$tmp" "$repos"
      printf '%s\n' "${repos#"$ENVMGR_MIGRATE_DATA"/}"
    fi
  done
}

envmgr_migrate_move() {
  local old="$1"
  local url="$2"
  local assume_yes="$3"
  local dry_run="$4"
  local ref=""
  local head=""
  local tags=0
  local branches=()
  local refspecs=()
  local changed=""
  local remote_refs=""

  envmgr_git_data fetch --quiet --prune --tags origin || envmgr_die 1 "could not fetch $old"
  envmgr_migrate_require_pushed
  remote_refs="$(git ls-remote "$url")" || envmgr_die 1 "could not reach $url"
  [[ -z "$remote_refs" ]] || \
    envmgr_die 1 "$url is not empty; create an empty repository for the migration"

  # Push origin's branches and tags, not --mirror: from a working checkout,
  # --mirror would also publish remote-tracking refs. The default branch goes
  # first so a new hosted repository adopts it as its default.
  head="$(envmgr_git_data symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || true)"
  while IFS= read -r ref; do
    [[ "$ref" == refs/remotes/origin/HEAD ]] && continue
    branches+=("${ref#refs/remotes/origin/}")
    if [[ "$ref" == "$head" ]]; then
      refspecs=("$ref:refs/heads/${ref#refs/remotes/origin/}" ${refspecs[@]+"${refspecs[@]}"})
    else
      refspecs+=("$ref:refs/heads/${ref#refs/remotes/origin/}")
    fi
  done < <(envmgr_git_data for-each-ref --format='%(refname)' refs/remotes/origin)
  ((${#refspecs[@]})) || envmgr_die 1 "origin has no branches to migrate"
  tags="$(envmgr_git_data tag --list | grep -c . || true)"

  printf 'migrate: will push %s\n' "$(envmgr_display_path "$ENVMGR_MIGRATE_DATA")"
  printf '  from      %s\n  to        %s\n' "$old" "$url"
  printf '  branches  %s\n  tags      %s\n' "${branches[*]}" "$tags"
  printf 'Then origin and data_url will point at the new URL, and git provider\n'
  printf 'entries for the old URL will be updated. The old repository is kept.\n'
  [[ "$dry_run" == true ]] && return 0
  envmgr_confirm "Push the data repository to $url?" "$assume_yes" || {
    printf 'migrate: cancelled\n'
    return 1
  }

  envmgr_git_data push --quiet "$url" "${refspecs[0]}" || return 1
  if ((${#refspecs[@]} > 1)); then
    envmgr_git_data push --quiet "$url" "${refspecs[@]:1}" || return 1
  fi
  if ((tags > 0)); then
    envmgr_git_data push --quiet "$url" 'refs/tags/*:refs/tags/*' || return 1
  fi
  envmgr_git_data remote set-url origin "$url"
  envmgr_kv_set "$(envmgr_local_config_file)" data_url "$url"
  envmgr_git_data fetch --quiet origin || envmgr_warn "could not fetch the new origin"
  printf 'migrate: pushed to %s; origin and data_url now point there.\n' "$url"

  changed="$(envmgr_migrate_manifests "$old" "$url")"
  if [[ -n "$changed" ]]; then
    printf 'Updated git provider entries (uncommitted):\n'
    printf '%s\n' "$changed" | sed 's/^/  /'
    printf 'Review, commit, and push them before migrating other machines.\n'
  fi
  printf 'On each other machine, run: envmgr migrate --follow %s\n' "$url"
}

envmgr_migrate_follow() {
  local old="$1"
  local url="$2"
  local dry_run="$3"
  local found=""

  # Fetch the new remote's branches into a private namespace, then check
  # that one of them contains this checkout's HEAD.
  envmgr_git_data fetch --quiet --no-tags "$url" '+refs/heads/*:refs/envmgr-follow/*' || \
    envmgr_die 1 "could not fetch $url"
  found="$(envmgr_git_data for-each-ref --contains HEAD --format='%(refname)' refs/envmgr-follow)"
  envmgr_git_data for-each-ref --format='delete %(refname)' refs/envmgr-follow | \
    envmgr_git_data update-ref --stdin
  [[ -n "$found" ]] || \
    envmgr_die 1 "$url does not contain this checkout's HEAD; push its commits to $old, then migrate them from the first machine again"

  printf 'migrate: %s contains this checkout.\n' "$url"
  printf '  origin    %s\n         -> %s\n' "$old" "$url"
  [[ "$dry_run" == true ]] && return 0
  envmgr_git_data remote set-url origin "$url"
  envmgr_kv_set "$(envmgr_local_config_file)" data_url "$url"
  envmgr_git_data fetch --quiet origin || envmgr_warn "could not fetch the new origin"
  printf 'migrate: origin and data_url now point at %s. Run envmgr restore to pull.\n' "$url"
}

envmgr_cmd_migrate() {
  local follow=false
  local assume_yes=false
  local dry_run=false
  local url=""
  local old=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --follow) follow=true ;;
      --yes|-y) assume_yes=true ;;
      --dry-run|-n) dry_run=true ;;
      -*) envmgr_usage_error "unknown option for migrate: $1" ;;
      *)
        [[ -z "$url" ]] || envmgr_usage_error "migrate takes one URL"
        url="$1"
        ;;
    esac
    shift
  done
  [[ -n "$url" ]] || envmgr_usage_error "migrate requires the new repository URL"

  ENVMGR_MIGRATE_DATA="$(envmgr_data_dir)"
  [[ -e "$ENVMGR_MIGRATE_DATA/.git" ]] || \
    envmgr_die 1 "the data repository is not a Git checkout: $ENVMGR_MIGRATE_DATA"
  old="$(envmgr_git_data remote get-url origin 2>/dev/null)" || \
    envmgr_die 1 "the data repository has no origin remote"
  if [[ "$old" == "$url" ]]; then
    [[ "$dry_run" == true ]] || envmgr_kv_set "$(envmgr_local_config_file)" data_url "$url"
    printf 'migrate: origin already is %s\n' "$url"
    return 0
  fi

  if [[ "$follow" == true ]]; then
    envmgr_migrate_follow "$old" "$url" "$dry_run"
  else
    envmgr_migrate_move "$old" "$url" "$assume_yes" "$dry_run"
  fi
}

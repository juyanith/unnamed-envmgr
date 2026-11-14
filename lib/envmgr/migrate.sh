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

# Move the data checkout aside and clone url in its place, so the path in
# data= and Chezmoi's sourceDir stays valid. Used when the new repository
# shares no history with the checkout.
envmgr_migrate_replace_checkout() {
  local url="$1"
  local aside=""
  local machine=""

  aside="$ENVMGR_MIGRATE_DATA.old-$(envmgr_timestamp)"
  mv -- "$ENVMGR_MIGRATE_DATA" "$aside" || return 1
  if ! git clone --quiet -- "$url" "$ENVMGR_MIGRATE_DATA"; then
    mv -- "$aside" "$ENVMGR_MIGRATE_DATA"
    envmgr_die 1 "could not clone $url; the old checkout was left in place"
  fi
  printf 'migrate: moved the old checkout to %s\n' "$(envmgr_display_path "$aside")"
  printf '         and cloned %s in its place.\n' "$url"
  machine="$(envmgr_kv_get "$(envmgr_local_config_file)" machine 2>/dev/null)" || return 0
  [[ -d "$ENVMGR_MIGRATE_DATA/machines/$machine" ]] || \
    envmgr_warn "the new repository has no machine $machine; run envmgr init <machine-id>"
}

envmgr_migrate_move() {
  local old="$1"
  local url="$2"
  local assume_yes="$3"
  local dry_run="$4"
  local no_history="$5"
  local ref=""
  local head=""
  local default=""
  local commit=""
  local tags=0
  local branches=()
  local others=()
  local refspecs=()
  local changed=""
  local remote_refs=""

  envmgr_git_data fetch --quiet --prune --tags origin || envmgr_die 1 "could not fetch $old"
  envmgr_migrate_require_pushed
  remote_refs="$(git ls-remote "$url")" || envmgr_die 1 "could not reach $url"
  [[ -z "$remote_refs" ]] || \
    envmgr_die 1 "$url is not empty; create an empty repository for the migration"

  head="$(envmgr_git_data symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || true)"
  [[ -n "$head" ]] || head="refs/remotes/origin/$(envmgr_git_data branch --show-current)"
  envmgr_git_data rev-parse --verify --quiet "$head" >/dev/null || \
    envmgr_die 1 "cannot tell origin's default branch; run git remote set-head origin --auto"
  default="${head#refs/remotes/origin/}"

  # Push origin's branches and tags, not --mirror: from a working checkout,
  # --mirror would also publish remote-tracking refs. The default branch goes
  # first so a new hosted repository adopts it as its default.
  while IFS= read -r ref; do
    [[ "$ref" == refs/remotes/origin/HEAD ]] && continue
    branches+=("${ref#refs/remotes/origin/}")
    if [[ "$ref" == "$head" ]]; then
      refspecs=("$ref:refs/heads/$default" ${refspecs[@]+"${refspecs[@]}"})
    else
      others+=("${ref#refs/remotes/origin/}")
      refspecs+=("$ref:refs/heads/${ref#refs/remotes/origin/}")
    fi
  done < <(envmgr_git_data for-each-ref --format='%(refname)' refs/remotes/origin)
  tags="$(envmgr_git_data tag --list | grep -c . || true)"

  printf 'migrate: will push %s\n' "$(envmgr_display_path "$ENVMGR_MIGRATE_DATA")"
  printf '  from      %s\n  to        %s\n' "$old" "$url"
  if [[ "$no_history" == true ]]; then
    printf '  copy      the current files of %s, as one new commit\n' "$default"
    printf '  omitted   history, %s tag(s), other branches: %s\n' "$tags" "${others[*]:-none}"
    printf 'Then this checkout moves to %s.old-<timestamp>, a clone of the new\n' \
      "$(envmgr_display_path "$ENVMGR_MIGRATE_DATA")"
    printf 'URL takes its place, and git provider entries for the old URL are\n'
    printf 'updated in it. The old repository is kept.\n'
  else
    printf '  branches  %s\n  tags      %s\n' "${branches[*]}" "$tags"
    printf 'Then origin and data_url will point at the new URL, and git provider\n'
    printf 'entries for the old URL will be updated. The old repository is kept.\n'
  fi
  [[ "$dry_run" == true ]] && return 0
  envmgr_confirm "Push the data repository to $url?" "$assume_yes" || {
    printf 'migrate: cancelled\n'
    return 1
  }

  if [[ "$no_history" == true ]]; then
    commit="$(envmgr_git_data commit-tree -m "Copy envmgr-data without its history" \
      "$head^{tree}")" || return 1
    envmgr_git_data push --quiet "$url" "$commit:refs/heads/$default" || return 1
    envmgr_migrate_replace_checkout "$url" || return 1
  else
    envmgr_git_data push --quiet "$url" "${refspecs[0]}" || return 1
    if ((${#refspecs[@]} > 1)); then
      envmgr_git_data push --quiet "$url" "${refspecs[@]:1}" || return 1
    fi
    if ((tags > 0)); then
      envmgr_git_data push --quiet "$url" 'refs/tags/*:refs/tags/*' || return 1
    fi
    envmgr_git_data remote set-url origin "$url"
    envmgr_git_data fetch --quiet origin || envmgr_warn "could not fetch the new origin"
  fi
  envmgr_kv_set "$(envmgr_local_config_file)" data_url "$url"
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
  local assume_yes="$3"
  local dry_run="$4"
  local found=""
  local ref=""
  local shared=false

  # Fetch the new remote's branches into a private namespace, then check
  # whether one of them contains this checkout's HEAD, or at least shares
  # history with it.
  envmgr_git_data fetch --quiet --no-tags "$url" '+refs/heads/*:refs/envmgr-follow/*' || \
    envmgr_die 1 "could not fetch $url"
  found="$(envmgr_git_data for-each-ref --contains HEAD --format='%(refname)' refs/envmgr-follow)"
  while IFS= read -r ref; do
    envmgr_git_data merge-base HEAD "$ref" >/dev/null 2>&1 && shared=true
  done < <(envmgr_git_data for-each-ref --format='%(refname)' refs/envmgr-follow)
  envmgr_git_data for-each-ref --format='delete %(refname)' refs/envmgr-follow | \
    envmgr_git_data update-ref --stdin

  if [[ -n "$found" ]]; then
    printf 'migrate: %s contains this checkout.\n' "$url"
    printf '  origin    %s\n         -> %s\n' "$old" "$url"
    [[ "$dry_run" == true ]] && return 0
    envmgr_git_data remote set-url origin "$url"
    envmgr_kv_set "$(envmgr_local_config_file)" data_url "$url"
    envmgr_git_data fetch --quiet origin || envmgr_warn "could not fetch the new origin"
    printf 'migrate: origin and data_url now point at %s. Run envmgr restore to pull.\n' "$url"
    return 0
  fi
  [[ "$shared" == false ]] || \
    envmgr_die 1 "$url does not contain this checkout's HEAD; push its commits to $old, then migrate them from the first machine again"

  # A copy made with --no-history: replace the checkout, but only when
  # nothing in it would be stranded in the old directory.
  envmgr_git_data fetch --quiet --prune origin || \
    envmgr_warn "could not fetch $old; checking against its last known state"
  envmgr_migrate_require_pushed
  printf 'migrate: %s is a copy without this checkout'\''s history.\n' "$url"
  printf 'This checkout will move to %s.old-<timestamp>, and a clone of the\n' \
    "$(envmgr_display_path "$ENVMGR_MIGRATE_DATA")"
  printf 'new URL takes its place. The selected machine stays the same.\n'
  [[ "$dry_run" == true ]] && return 0
  envmgr_confirm "Replace the data checkout with a clone of $url?" "$assume_yes" || {
    printf 'migrate: cancelled\n'
    return 1
  }
  envmgr_migrate_replace_checkout "$url" || return 1
  envmgr_kv_set "$(envmgr_local_config_file)" data_url "$url"
  printf 'migrate: data_url now points at %s. Run envmgr check, then envmgr restore.\n' "$url"
}

envmgr_cmd_migrate() {
  local follow=false
  local no_history=false
  local assume_yes=false
  local dry_run=false
  local url=""
  local old=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --follow) follow=true ;;
      --no-history) no_history=true ;;
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
  [[ "$follow" == false || "$no_history" == false ]] || \
    envmgr_usage_error "--follow detects a copy made with --no-history by itself"

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
    envmgr_migrate_follow "$old" "$url" "$assume_yes" "$dry_run"
  else
    envmgr_migrate_move "$old" "$url" "$assume_yes" "$dry_run" "$no_history"
  fi
}

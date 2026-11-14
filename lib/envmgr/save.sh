#!/usr/bin/env bash
# envmgr save: commit the active machine's directory in the data checkout and
# push it to origin.

envmgr_git_save() {
  git -C "$ENVMGR_SAVE_DATA" "$@"
}

# Print the absolute path of a file in the data checkout's Git directory.
envmgr_save_git_path() {
  local path=""

  path="$(envmgr_git_save rev-parse --git-path "$1")" || return 1
  [[ "$path" == /* ]] || path="$ENVMGR_SAVE_DATA/$path"
  printf '%s\n' "$path"
}

# Print the branch the machine's git provider entry tracks for the data
# checkout, or main when there is no entry.
envmgr_data_branch() {
  local data="$1"
  local machine_dir="$2"
  local data_real=""
  local path=""
  local branch=""

  data_real="$(cd -P -- "$data" && pwd)"
  while IFS=$'\t' read -r _ path branch; do
    path="$(envmgr_expand_path "$path")"
    [[ -d "$path" ]] || continue
    if [[ "$(cd -P -- "$path" && pwd)" == "$data_real" ]]; then
      printf '%s\n' "$branch"
      return 0
    fi
  done < <(ENVMGR_MANIFEST_DIR="$machine_dir/packages/git" envmgr_git_entries)
  printf 'main\n'
}

# Print the target name a Chezmoi source name stands for, such as .netrc for
# encrypted_private_dot_netrc.age.
envmgr_save_target_name() {
  local name="$1"

  name="${name%.tmpl}"
  name="${name%.age}"
  name="${name%.asc}"
  while :; do
    case "$name" in
      encrypted_*) name="${name#encrypted_}" ;;
      private_*) name="${name#private_}" ;;
      readonly_*) name="${name#readonly_}" ;;
      empty_*) name="${name#empty_}" ;;
      executable_*) name="${name#executable_}" ;;
      exact_*) name="${name#exact_}" ;;
      *) break ;;
    esac
  done
  case "$name" in
    dot_*) name=".${name#dot_}" ;;
  esac
  printf '%s\n' "$name"
}

# Refuse to commit config sources that look like plaintext secrets: a source
# beside an encrypted source for the same target, a name adopt requires
# --encrypt for, or a private key in the content.
envmgr_save_check_secrets() {
  local machine="$1"
  local file=""
  local base=""
  local name=""
  local sibling=""

  while IFS= read -r file; do
    [[ "$file" == "machines/$machine/config/"* ]] || continue
    base="$(basename -- "$file")"
    [[ "$base" == encrypted_* || "$base" == *.age ]] && continue
    case "$base" in
      modify_*|run_*|.chezmoi*) continue ;;
    esac
    name="$(envmgr_save_target_name "$base")"
    for sibling in "$ENVMGR_SAVE_DATA/$(dirname -- "$file")"/*; do
      [[ -e "$sibling" ]] || continue
      case "$(basename -- "$sibling")" in
        encrypted_*|*.age) ;;
        *) continue ;;
      esac
      [[ "$(envmgr_save_target_name "$(basename -- "$sibling")")" == "$name" ]] && \
        envmgr_die 1 "$file is a plaintext copy of an encrypted target; remove it before saving"
    done
    if envmgr_looks_secret_name "$name" || \
      grep -Eq -- '-----BEGIN ([A-Z]+ )?PRIVATE KEY-----|AGE-SECRET-KEY-' "$ENVMGR_SAVE_DATA/$file" 2>/dev/null; then
      envmgr_die 1 "$file looks like a secret; adopt its target with --encrypt instead"
    fi
  done
}

# Summarize changed paths under the machine directory, one category per line,
# for the default commit message.
envmgr_save_summary() {
  local machine="$1"

  awk -v prefix="machines/$machine/" '
    index($0, prefix) != 1 { next }
    {
      rest = substr($0, length(prefix) + 1)
      n = split(rest, part, "/")
      if (part[1] == "config") { cat = "config"; item = substr(rest, 8) }
      else if (part[1] == "packages") { cat = "package"; item = part[2] }
      else if (part[1] == "system") { cat = "system"; item = part[2] }
      else { cat = "machine"; item = rest }
      key = cat SUBSEP item
      if (key in seen) next
      seen[key] = 1
      if (!(cat in items)) order[++count] = cat
      items[cat] = (cat in items) ? items[cat] ", " item : item
    }
    END { for (i = 1; i <= count; i++) print order[i] ": " items[order[i]] }
  '
}

envmgr_cmd_save() {
  local message=""
  local push=true
  local assume_yes=false
  local dry_run=false
  local machine_dir=""
  local machine=""
  local dir=""
  local branch=""
  local current=""
  local index=""
  local changed=""
  local added=""
  local preview=""
  local others=""
  local outside=""
  local ahead=0
  local behind=0
  local rc=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -m|--message)
        [[ $# -ge 2 && -n "$2" ]] || envmgr_usage_error "$1 requires a message"
        message="$2"
        shift
        ;;
      --no-push) push=false ;;
      --yes|-y) assume_yes=true ;;
      --dry-run|-n) dry_run=true ;;
      *) envmgr_usage_error "unknown argument for save: $1" ;;
    esac
    shift
  done

  machine_dir="$(envmgr_active_machine_dir warn)"
  machine="$(basename -- "$machine_dir")"
  dir="machines/$machine"
  ENVMGR_SAVE_DATA="$(dirname -- "$(dirname -- "$machine_dir")")"
  [[ -e "$ENVMGR_SAVE_DATA/.git" ]] || \
    envmgr_die 1 "the data repository is not a Git checkout: $ENVMGR_SAVE_DATA"
  envmgr_git_save remote get-url origin >/dev/null 2>&1 || \
    envmgr_die 1 "the data repository has no origin remote"

  branch="$(envmgr_data_branch "$ENVMGR_SAVE_DATA" "$machine_dir")"
  current="$(envmgr_git_save branch --show-current)"
  [[ "$current" == "$branch" ]] || \
    envmgr_die 1 "the data checkout is on branch ${current:-(detached)}, expected $branch"
  [[ ! -e "$(envmgr_save_git_path rebase-merge)" && \
    ! -e "$(envmgr_save_git_path rebase-apply)" && \
    ! -e "$(envmgr_save_git_path MERGE_HEAD)" ]] || \
    envmgr_die 1 "the data checkout has a rebase or merge in progress; finish it first"

  if ! envmgr_git_save fetch --quiet origin "$branch"; then
    [[ "$push" == false ]] || envmgr_die 1 "could not fetch origin"
    envmgr_warn "could not fetch origin; comparing against its last known state"
  fi
  if envmgr_git_save rev-parse --verify --quiet "origin/$branch" >/dev/null; then
    ahead="$(envmgr_git_save rev-list --count "origin/$branch..HEAD")" || return 1
    behind="$(envmgr_git_save rev-list --count "HEAD..origin/$branch")" || return 1
  elif envmgr_git_save rev-parse --verify --quiet HEAD >/dev/null; then
    ahead="$(envmgr_git_save rev-list --count HEAD)" || return 1
  fi

  # Stage into a scratch copy of the index, so the preview and the checks see
  # new, changed, and deleted files exactly as the commit will.
  index="$(mktemp "${TMPDIR:-/tmp}/envmgr-index.XXXXXX")"
  if [[ -f "$(envmgr_save_git_path index)" ]]; then
    cp -- "$(envmgr_save_git_path index)" "$index"
  else
    rm -f -- "$index"
  fi
  if GIT_INDEX_FILE="$index" envmgr_git_save add -A -- "$dir"; then
    changed="$(GIT_INDEX_FILE="$index" envmgr_git_save diff --cached --name-only -- "$dir")"
    added="$(GIT_INDEX_FILE="$index" envmgr_git_save diff --cached --name-only --diff-filter=d -- "$dir")"
    preview="$(
      GIT_INDEX_FILE="$index" envmgr_git_save -c color.status=never status --short -- "$dir"
      GIT_INDEX_FILE="$index" envmgr_git_save diff --cached --stat -- "$dir"
    )"
  else
    rc=1
  fi
  rm -f -- "$index"
  [[ "$rc" -eq 0 ]] || return 1
  others="$(envmgr_git_save status --porcelain -- . ":(exclude)$dir")"

  if [[ -z "$changed" && ( "$push" == false || "$ahead" -eq 0 ) ]]; then
    [[ -z "$others" ]] || envmgr_warn "changes outside $dir are not saved; commit them with git"
    printf 'save: nothing to save for %s\n' "$machine"
    return 0
  fi

  printf '%s\n' "$added" | envmgr_save_check_secrets "$machine"
  if [[ "$push" == true && "$behind" -gt 0 ]]; then
    outside="$(envmgr_git_save log --name-only --format= "origin/$branch..HEAD" | \
      grep -v "^$dir/" | grep -v '^$' || true)"
    [[ -z "$outside" ]] || \
      envmgr_die 1 "origin has $behind new commit(s), and local commits change files outside $dir; pull and resolve with git"
    [[ -z "$(envmgr_git_save status --porcelain --untracked-files=no -- . ":(exclude)$dir")" ]] || \
      envmgr_die 1 "origin has $behind new commit(s), and uncommitted changes outside $dir would block pulling them; commit or stash them, or rerun with --no-push"
  fi
  [[ -n "$message" ]] || message="$(
    printf 'Update %s\n\n' "$machine"
    printf '%s\n' "$changed" | envmgr_save_summary "$machine"
  )"

  printf 'save: %s in %s\n' "$dir" "$(envmgr_display_path "$ENVMGR_SAVE_DATA")"
  if [[ -n "$changed" ]]; then
    printf '%s\n' "$preview" | sed 's/^/  /'
    printf 'Commit message:\n'
    printf '%s\n' "$message" | sed 's/^/  /'
  fi
  if [[ -n "$others" ]]; then
    envmgr_warn "these changes outside $dir are not saved:"
    printf '%s\n' "$others" | sed 's/^/  /' >&2
  fi
  if [[ "$push" == true ]]; then
    [[ "$ahead" -eq 0 ]] || printf '%s earlier commit(s) are not pushed yet.\n' "$ahead"
    [[ "$behind" -eq 0 ]] || printf 'origin has %s new commit(s); local commits will be rebased onto them.\n' "$behind"
    printf 'Then push to origin/%s.\n' "$branch"
  fi
  [[ "$dry_run" == true ]] && return 0
  envmgr_confirm "Save these changes?" "$assume_yes" || {
    printf 'save: cancelled\n'
    return 1
  }

  if [[ -n "$changed" ]]; then
    envmgr_git_save add -A -- "$dir" || return 1
    # The pathspec commits only this machine's directory and leaves anything
    # else staged as it was.
    envmgr_git_save commit --quiet -m "$message" -- "$dir" || \
      envmgr_die 1 "git commit failed; the changes are staged in $(envmgr_display_path "$ENVMGR_SAVE_DATA")"
    printf 'save: committed %s\n' "$(envmgr_git_save rev-parse --short HEAD)"
  fi
  [[ "$push" == true ]] || return 0

  if [[ "$behind" -gt 0 ]]; then
    envmgr_git_save rebase --quiet "origin/$branch" >/dev/null 2>&1 || rc=$?
    if [[ "$rc" -ne 0 ]]; then
      envmgr_git_save rebase --abort >/dev/null 2>&1 || true
      envmgr_die 1 "origin's new commits conflict with this machine's; the commit is local only. Rebase onto origin/$branch with git, then run envmgr save again"
    fi
  fi
  envmgr_git_save push --quiet origin "HEAD:refs/heads/$branch" || \
    envmgr_die 1 "push failed; the commit is local only. Run envmgr save again to retry"
  printf 'save: pushed to origin/%s\n' "$branch"
}

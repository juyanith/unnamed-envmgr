#!/usr/bin/env bash
# git provider: keeps declared checkouts present and fast-forwarded.
# Manifest: repos, one "url path [branch]" per line (branch defaults to main).

envmgr_git_entries() {
  [[ -f "$ENVMGR_MANIFEST_DIR/repos" ]] || return 0
  awk '!/^[[:space:]]*(#|$)/ { print $1 "\t" $2 "\t" ($3 == "" ? "main" : $3) }' \
    "$ENVMGR_MANIFEST_DIR/repos"
}

# Describe why a checkout cannot fast-forward, or print nothing.
envmgr_git_blocker() {
  local path="$1"
  local branch="$2"
  local current=""

  current="$(git -C "$path" branch --show-current)"
  if [[ "$current" != "$branch" ]]; then
    printf 'on branch %s, expected %s' "${current:-(detached)}" "$branch"
  elif [[ -n "$(git -C "$path" status --porcelain)" ]]; then
    printf 'uncommitted changes'
  elif [[ "$(git -C "$path" rev-list --count "origin/$branch..HEAD")" -gt 0 ]]; then
    printf 'unpushed commits'
  fi
}

envmgr_git_behind() {
  local path="$1"
  local branch="$2"

  git -C "$path" rev-parse --verify --quiet "origin/$branch" >/dev/null || {
    printf '0\n'
    return 0
  }
  git -C "$path" rev-list --count "HEAD..origin/$branch"
}

envmgr_pkg_git_available() {
  command -v git >/dev/null 2>&1
}

envmgr_pkg_git_bootstrap() {
  printf 'envmgr: error: git is required; run envmgr setup\n' >&2
  return 1
}

envmgr_pkg_git_refresh() {
  local url=""
  local path=""
  local branch=""
  local rc=0

  while IFS=$'\t' read -r url path branch; do
    path="$(envmgr_expand_path "$path")"
    [[ -d "$path/.git" ]] || continue
    git -C "$path" fetch --quiet origin "$branch" || rc=1
  done < <(envmgr_git_entries)
  return "$rc"
}

envmgr_pkg_git_list() {
  local url=""
  local path=""
  local branch=""

  while IFS=$'\t' read -r url path branch; do
    printf '%s\n' "$path"
  done < <(envmgr_git_entries)
}

envmgr_pkg_git_missing() {
  local url=""
  local path=""
  local branch=""

  while IFS=$'\t' read -r url path branch; do
    [[ -e "$(envmgr_expand_path "$path")" ]] || printf '%s\n' "$path"
  done < <(envmgr_git_entries)
}

envmgr_pkg_git_pending() {
  local url=""
  local path=""
  local branch=""
  local full=""
  local behind=""
  local blocker=""

  while IFS=$'\t' read -r url path branch; do
    full="$(envmgr_expand_path "$path")"
    [[ -d "$full/.git" ]] || continue
    behind="$(envmgr_git_behind "$full" "$branch")" || return 1
    [[ "$behind" -gt 0 ]] || continue
    blocker="$(envmgr_git_blocker "$full" "$branch")" || return 1
    if [[ -n "$blocker" ]]; then
      printf '%s: %s commit(s) behind; blocked by %s\n' "$path" "$behind" "$blocker"
    else
      printf '%s: %s commit(s) behind\n' "$path" "$behind"
    fi
  done < <(envmgr_git_entries)
}

envmgr_pkg_git_restore() {
  local url=""
  local path=""
  local branch=""
  local full=""
  local blocker=""

  while IFS=$'\t' read -r url path branch; do
    full="$(envmgr_expand_path "$path")"
    if [[ ! -e "$full" ]]; then
      mkdir -p -- "$(dirname -- "$full")"
      git clone --quiet --branch "$branch" -- "$url" "$full" || return 1
      printf 'package/git: cloned %s\n' "$path"
      continue
    fi
    [[ -d "$full/.git" ]] || {
      envmgr_warn "$path exists but is not a Git checkout; skipped"
      continue
    }
    [[ "$(envmgr_git_behind "$full" "$branch")" -gt 0 ]] || continue
    blocker="$(envmgr_git_blocker "$full" "$branch")"
    if [[ -n "$blocker" ]]; then
      envmgr_warn "$path not updated: $blocker"
      continue
    fi
    git -C "$full" merge --ff-only --quiet "origin/$branch" || return 1
    printf 'package/git: fast-forwarded %s\n' "$path"
  done < <(envmgr_git_entries)
}

envmgr_pkg_git_adopt() {
  local target=""
  local path=""
  local url=""
  local branch=""

  for target in "$@"; do
    target="$(envmgr_absolute_target "$target")" || return 1
    [[ -d "$target/.git" ]] || envmgr_die 1 "not a Git checkout: $target"
    url="$(git -C "$target" remote get-url origin)" || envmgr_die 1 "$target has no origin remote"
    branch="$(git -C "$target" branch --show-current)"
    [[ -n "$branch" ]] || envmgr_die 1 "$target is not on a branch"
    path="$(envmgr_display_path "$target")"
    if envmgr_pkg_git_list | grep -Fxq -- "$path"; then
      printf 'package/git: %s is already declared\n' "$path"
      continue
    fi
    printf '%s %s %s\n' "$url" "$path" "$branch" >>"$ENVMGR_MANIFEST_DIR/repos"
    printf 'package/git: adopted %s\n' "$path"
  done
}

envmgr_pkg_git_forget() {
  local target=""
  local paths=()

  for target in "$@"; do
    paths+=("$(envmgr_display_path "$(envmgr_absolute_target "$target")")")
  done
  envmgr_manifest_filter "$ENVMGR_MANIFEST_DIR/repos" '
    BEGIN { n = split(names, list, " "); for (i = 1; i <= n; i++) drop[list[i]] = 1 }
    /^[[:space:]]*(#|$)/ { print; next }
    !($2 in drop) { print }
  ' "${paths[@]}"
}

envmgr_pkg_git_uninstall() {
  printf 'envmgr: error: envmgr does not delete Git checkouts; remove them yourself: %s\n' "$*" >&2
  return 1
}

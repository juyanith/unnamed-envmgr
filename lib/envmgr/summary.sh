#!/usr/bin/env bash
# Per-category check results and the shared change_summary marker.

envmgr_result_file() {
  printf '%s\n' "$(envmgr_state_dir)/check/$1"
}

# Record a category result. Arguments after the category are key=value lines;
# drift is any value other than 0 or empty.
envmgr_record_result() {
  local category="$1"
  local file=""
  local tmp=""

  shift
  file="$(envmgr_result_file "$category")"
  mkdir -p -- "$(dirname -- "$file")"
  tmp="$(mktemp "$file.XXXXXX")"
  printf '%s\n' "$@" >"$tmp"
  mv -f -- "$tmp" "$file"
}

# Rebuild change_summary from every recorded category result. The marker
# exists only while some category reports drift.
envmgr_refresh_summary() {
  local machine="$1"
  local state=""
  local marker=""
  local tmp=""
  local category=""
  local file=""
  local drift=false

  state="$(envmgr_state_dir)"
  marker="$state/change_summary"
  mkdir -p -- "$state"
  tmp="$(mktemp "$marker.XXXXXX")"
  {
    printf 'machine=%s\n' "$machine"
    printf 'checked=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$tmp"

  for category in config package system; do
    file="$(envmgr_result_file "$category")"
    [[ -r "$file" ]] || continue
    cat -- "$file" >>"$tmp"
    if awk -F= 'NF > 1 && $2 != "" && $2 != "0" { found = 1 } END { exit !found }' "$file"; then
      drift=true
    fi
  done

  if [[ "$drift" == true ]]; then
    mv -f -- "$tmp" "$marker"
  else
    rm -f -- "$tmp" "$marker"
  fi
}

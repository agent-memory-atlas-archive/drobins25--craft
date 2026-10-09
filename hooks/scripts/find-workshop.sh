#!/bin/bash
# find-workshop.sh — Find the workshop: resolve the active Craft project root.
# This is craft's "is there a workshop here?" oracle - resolution failing means
# the project is not onboarded, and callers may branch on that (cold paths).
# Usage: source this file, then use $PROJECT_ROOT
#
# Resolution order:
#   1. CRAFT_PROJECT_ROOT env var (set by session-start or /craft:project)
#   2. Walk up from PWD looking for .craft/ (handles cd into sub-project)
#   3. If walk-up finds monorepo root, check .craft/.pinned-project first
#   4. If no pin, check for sub-projects
#
# Sets:
#   PROJECT_ROOT      — absolute path with trailing slash (e.g., /path/to/project/)
#   CRAFT_PROJECT_NAME — human-friendly name (empty if unknown)
#   CRAFT_MULTI_PROJECT — "true" if multiple projects detected and unresolved

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Walk up from PWD to find nearest .craft/ directory
_find_nearest_craft() {
  local dir="$PWD"
  # Prefer .craft/.global-state (fully initialized project)
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/.craft/.global-state" ]; then
      echo "$dir/"
      return 0
    fi
    dir=$(dirname "$dir")
  done
  # Fallback: .craft/ directory with project.md (but no .global-state)
  # Bare .craft/ directories (created by accident) are NOT valid project roots
  dir="$PWD"
  while [ "$dir" != "/" ]; do
    if [ -d "$dir/.craft" ] && [ -f "$dir/.craft/project.md" ]; then
      echo "$dir/"
      return 0
    fi
    dir=$(dirname "$dir")
  done
  return 1
}

# Check if a directory is the git repo root (monorepo root)
_is_repo_root() {
  local dir="${1%/}"
  local repo_root
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  [ "$dir" = "$repo_root" ]
}

# Check if repo root has sub-projects with their own .craft/
_has_sub_projects() {
  local repo_root
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1

  local count=0
  # Check registry first
  if [ -d "$repo_root/.craft/projects" ]; then
    for f in "$repo_root/.craft/projects"/*.md; do
      [ -f "$f" ] || continue
      local path
      path=$(sed -n '/^---$/,/^---$/p' "$f" 2>/dev/null | grep "^path:" | head -1 | sed 's/^path: *//' | tr -d '"' | tr -d "'")
      [ -z "$path" ] && continue
      [ -d "$repo_root/$path/.craft" ] && count=$((count + 1))
    done
  fi

  [ "$count" -gt 0 ]
}

# Find the single active sub-project (has ACTIVE_CYCLE set)
_find_active_sub_project() {
  local repo_root
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1

  local active_path="" active_name="" active_count=0

  if [ -d "$repo_root/.craft/projects" ]; then
    for f in "$repo_root/.craft/projects"/*.md; do
      [ -f "$f" ] || continue
      local name path
      name=$(sed -n '/^---$/,/^---$/p' "$f" 2>/dev/null | grep "^name:" | head -1 | sed 's/^name: *//' | tr -d '"' | tr -d "'")
      path=$(sed -n '/^---$/,/^---$/p' "$f" 2>/dev/null | grep "^path:" | head -1 | sed 's/^path: *//' | tr -d '"' | tr -d "'")
      [ -z "$name" ] || [ -z "$path" ] && continue

      local abs_path="$repo_root/$path"
      if [ -f "$abs_path/.craft/.global-state" ]; then
        local cycle
        cycle=$(grep "^ACTIVE_CYCLE=" "$abs_path/.craft/.global-state" 2>/dev/null | sed 's/ACTIVE_CYCLE=//' | tr -d '"')
        if [ -n "$cycle" ]; then
          active_path="$abs_path/"
          active_name="$name"
          active_count=$((active_count + 1))
        fi
      fi
    done
  fi

  if [ "$active_count" -eq 1 ]; then
    echo "${active_name}|${active_path}"
    return 0
  fi
  return 1
}

# Main resolution
if [ -z "${PROJECT_ROOT:-}" ]; then

  # 1. Check CRAFT_PROJECT_ROOT env var (session-pinned)
  if [ -n "${CRAFT_PROJECT_ROOT:-}" ]; then
    local_root="${CRAFT_PROJECT_ROOT%/}/"
    if [ -d "${local_root}.craft" ]; then
      PROJECT_ROOT="$local_root"
      CRAFT_PROJECT_NAME="${CRAFT_PROJECT_NAME:-}"
    else
      # Env var points to invalid location — fall through
      unset CRAFT_PROJECT_ROOT
    fi
  fi

  # 2. Walk up from PWD
  if [ -z "${PROJECT_ROOT:-}" ]; then
    nearest=$(_find_nearest_craft) || true

    if [ -n "$nearest" ]; then
      # Check: did we land on the monorepo root which has sub-projects?
      if _is_repo_root "${nearest%/}" && _has_sub_projects; then
        # Check for persistent project pin first
        _pin_file="${nearest}.craft/.pinned-project"
        if [ -f "$_pin_file" ]; then
          _pinned_root=$(head -1 "$_pin_file" 2>/dev/null | tr -d '[:space:]')
          _pinned_name=$(sed -n '2p' "$_pin_file" 2>/dev/null | tr -d '[:space:]')
          if [ -n "$_pinned_root" ] && [ -d "${_pinned_root%/}/.craft" ]; then
            PROJECT_ROOT="${_pinned_root%/}/"
            CRAFT_PROJECT_NAME="${_pinned_name:-}"
          else
            # Pin file invalid — fall through to auto-detect
            PROJECT_ROOT="$nearest"
            CRAFT_MULTI_PROJECT="true"
          fi
        else
          # No pin — try to auto-select the single active sub-project
          active_info=$(_find_active_sub_project) || true
          if [ -n "$active_info" ]; then
            CRAFT_PROJECT_NAME="${active_info%%|*}"
            PROJECT_ROOT="${active_info#*|}"
          else
            # Multiple active or none — can't auto-resolve
            PROJECT_ROOT="$nearest"
            CRAFT_MULTI_PROJECT="true"
          fi
        fi
      else
        # Found a non-root .craft/ — use it directly
        PROJECT_ROOT="$nearest"
      fi
    fi
  fi

  # 3. Final fallback — error if nothing found
  if [ -z "${PROJECT_ROOT:-}" ]; then
    # Return silently instead of erroring — hooks should exit 0, not crash
    return 1 2>/dev/null || exit 1
  fi
fi

# Export for subshells
export PROJECT_ROOT
export CRAFT_PROJECT_NAME
export CRAFT_MULTI_PROJECT

#!/bin/bash
# annotate-root.sh - The one project-folder lookup the three annotate scripts
# (annotate-run.sh, annotate-resolve.sh, annotate-record.sh) share. Sourced; it
# defines annotate_root and runs nothing on source.
#
# annotate_root <given> <name>
#   Prints a project folder with no trailing slash, or nothing. Always exits 0.
#   <given> is the --root value; <name> is the session id or record name the
#   command acts on, empty for a command that names none.
#
#   1. <given>, when non-empty.
#   2. The folder craft already knows: CRAFT_PROJECT_ROOT, else the project the
#      set-up check finds (find-workshop.sh).
#   3. A command that names nothing (or a name that is not a plain folder name)
#      stops here with that folder.
#   4. That folder, when it holds .craft/annotations/<name>.
#   5. Otherwise the nearest folder at or above the current one that holds
#      .craft/annotations/<name>. A session id is minted from a pid and a
#      timestamp, so the walk can only land where the session was armed. On a
#      project that never ran /craft:init the set-up check finds nothing, and
#      this walk is what lets every later command reach the session without
#      repeating --root.
#   6. Otherwise the folder from step 2, so the caller reports a missing session.
#
# The walk only lands on a folder that already exists; it never chooses where a
# new session is made, so arm without a root still refuses.

annotate_root() {
  local given="${1:-}" name="${2:-}" found="" dir
  if [ -n "$given" ]; then
    echo "${given%/}"
    return 0
  fi
  if [ -n "${CRAFT_PROJECT_ROOT:-}" ]; then
    found="$CRAFT_PROJECT_ROOT"
  else
    found="$(source "$(dirname "${BASH_SOURCE[0]}")/find-workshop.sh" >/dev/null 2>&1; echo "${PROJECT_ROOT:-}")" || found=""
  fi
  found="${found%/}"

  case "$name" in
    ''|*/*|.*)
      echo "$found"
      return 0
      ;;
  esac
  if [ -n "$found" ] && [ -d "$found/.craft/annotations/$name" ]; then
    echo "$found"
    return 0
  fi

  dir="$PWD"
  while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    if [ -d "$dir/.craft/annotations/$name" ]; then
      echo "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  echo "$found"
  return 0
}

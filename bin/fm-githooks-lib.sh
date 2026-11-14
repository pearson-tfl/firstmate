#!/usr/bin/env bash
# Point a project clone at its tracked .githooks/ directory.
#
# A repository that tracks .githooks/ expects core.hooksPath=.githooks, but git
# never sets that on clone, so its hooks would silently not run. This file is
# the single owner of that rule; bin/fm-home-seed.sh applies it when it clones
# a project into a home, and bin/fm-fleet-sync.sh applies it on every refresh,
# which also covers clones made by any other path.
#
# fm_githooks_apply <clone-root>
#   Sets core.hooksPath=.githooks in the clone's local config when the clone's
#   index tracks at least one file under .githooks/ and core.hooksPath is unset
#   there. A clone that tracks no .githooks/ is never touched, and an existing
#   local core.hooksPath (for example husky's) is left as the project set it.
#   The caller must pass the root of the clone's own work tree, since git
#   discovery would otherwise act on an enclosing repository. Always returns 0:
#   a failure leaves hooks as they were and must not stop a clone or a sync.

fm_githooks_apply() {
  local dir=$1
  [ -n "$(git -C "$dir" ls-files -- .githooks 2>/dev/null | head -1)" ] || return 0
  git -C "$dir" config --local --get core.hooksPath >/dev/null 2>&1 && return 0
  git -C "$dir" config --local core.hooksPath .githooks 2>/dev/null || true
  return 0
}

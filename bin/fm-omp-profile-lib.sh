#!/usr/bin/env bash
# fm-omp-profile-lib.sh - the single owner of which omp profile (`omp --profile
# <name>`: omp's own isolated auth, sessions, settings, and caches) an omp
# launch runs on: the usage-based pick, the per-secondmate pin that overrides
# it, how each profile maps to its login, and the refusals.
#
# docs/configuration.md "omp profile choice" owns the operator-facing
# contract. Sourced by bin/fm-spawn.sh, bin/fm-control.sh, and
# bin/fm-exhaust-switch.sh.
#
# Usage-based pick. Every canonical omp launch - ship, scout, or local
# secondmate, at spawn, relaunch, and recovery - picks the named profile under
# omp's own root ($HOME/${PI_CONFIG_DIR:-.omp}/profiles, the rule omp itself
# uses) whose Anthropic login has the most usage left. A profile's login is
# its enabled anthropic row in agent/agent.db auth_credentials (read-only),
# matched to a cswap account by login and organization; usage, the
# config/account-rules forbid and project lines, and the exhausted-login
# record all come from bin/fm-worker-account-lib.sh's fm_account_rules_ranked,
# so profiles that share a login share one budget. A login cswap does not list
# ranks after every listed one, as unknown usage. A machine with no named
# profile keeps today's ambient launch byte for byte; a machine whose profiles
# are all exhausted, forbidden, or out of headroom refuses rather than landing
# on one. Profiles without an Anthropic login are never picked.
#
# The pin is config/secondmate-accounts/<id>/omp-profile in the launching
# (primary) home, read only for a local secondmate's own omp agent. It is the
# explicit override: it wins over the pick unless its login is recorded
# exhausted, in which case the launch picks by usage and says so. A present
# file must hold one profile name matching omp's own rule (omp 18.4.3:
# ^[a-z0-9][a-z0-9._-]{0,63}$, never ending in ".", never a Windows reserved
# device name with or without an extension), with an optional final newline;
# anything else refuses before any endpoint, worktree, or record exists. A raw
# omp launch command runs verbatim and cannot receive the flag, so a pinned
# mate refuses it and an unpinned one keeps its own command unchanged.

# shellcheck source=bin/fm-agent-process-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-agent-process-lib.sh"
# shellcheck source=bin/fm-worker-account-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-worker-account-lib.sh"

# fm_omp_profile_read <file>
# Prints the profile name for a valid pin. Parses bytes before the shell can
# drop NULs or trailing newlines. Returns 0 on success, 3 when the file does
# not exist, 4 when it cannot be inspected (one error already printed), 5 when
# it is not a readable regular file, and 6 when it is malformed.
fm_omp_profile_read() {
  perl -MErrno=ENOENT -e '
    my ($f) = @ARGV;
    unless (lstat $f) {
      exit 3 if $! == ENOENT;
      print STDERR "error: cannot inspect configuration source at $f: $!\n";
      exit 4;
    }
    (-f $f && -r _) or exit 5;
    open(my $fh, "<", $f) or exit 5;
    my $body = do { local $/; <$fh> } // "";
    $body =~ /\A([a-z0-9][a-z0-9._-]{0,63})\n?\z/ or exit 6;
    my $name = $1;
    $name =~ /\.\z/ and exit 6;
    $name =~ /\A(?:con|prn|aux|nul|com[0-9]|lpt[0-9])(?:\.|\z)/ and exit 6;
    print $name;
  ' -- "$1"
}

# fm_omp_root: omp's config root, by omp's own rule (path.join of the home
# directory and PI_CONFIG_DIR, default .omp); FM_OMP_ROOT replaces it for tests.
fm_omp_root() {
  local dir=${PI_CONFIG_DIR:-.omp}
  printf '%s\n' "${FM_OMP_ROOT:-${HOME%/}/${dir#/}}"
}

# fm_omp_profile_logins <cswap-list-json> [<profile>]
# Prints "<profile><TAB><login>" for each named profile (or just the one given)
# that holds an enabled Anthropic login: cswap:<num> when cswap lists that
# login, otherwise login:<12-hex digest of login and organization>. Nothing is
# printed for a profile without one. Never prints a login itself.
fm_omp_profile_logins() {
  local list=$1 only=${2:-} dir name db row email org num
  if ! command -v sqlite3 >/dev/null 2>&1; then
    [ -z "$(find "$(fm_omp_root)/profiles" -mindepth 3 -maxdepth 3 -name agent.db 2>/dev/null | head -n 1)" ] \
      || echo "warning: sqlite3 not found; omp profile logins cannot be read, so omp profiles are not chosen by usage" >&2
    return 0
  fi
  for dir in "$(fm_omp_root)"/profiles/*/; do
    name=${dir%/}
    name=${name##*/}
    [ -z "$only" ] || [ "$name" = "$only" ] || continue
    db="$dir/agent/agent.db"
    [ -f "$db" ] || continue
    row=$(sqlite3 -readonly -separator $'\t' "$db" \
      "select json_extract(data,'\$.email'), json_extract(data,'\$.orgId') from auth_credentials
       where provider = 'anthropic' and disabled_cause is null order by id limit 1" 2>/dev/null) || continue
    [ -n "$row" ] || continue
    email=${row%%$'\t'*}
    org=${row#*$'\t'}
    num=$(printf '%s\n' "$list" | jq -r --arg e "$email" --arg o "$org" \
      'first(.accounts[]? | select((.email // "" | ascii_downcase) == ($e | ascii_downcase)
        and ($o == "" or .organizationUuid == null or .organizationUuid == $o)) | .number) // empty' 2>/dev/null)
    if [ -n "$num" ]; then
      printf '%s\tcswap:%s\n' "$name" "$num"
    else
      printf '%s\tlogin:%s\n' "$name" "$(printf '%s|%s' "$email" "$org" | tr '[:upper:]' '[:lower:]' | shasum -a 256 | cut -c1-12)"
    fi
  done
}

# fm_omp_profile_login <profile> [<cswap-list-json>]
# Prints one profile's login key: its fm_omp_profile_logins key, or
# omp:<profile> when it holds no Anthropic login (its own budget).
fm_omp_profile_login() {
  local key
  key=$(fm_omp_profile_logins "${2:-}" "$1" | cut -f2)
  printf '%s\n' "${key:-omp:$1}"
}

# fm_omp_profile_pick <config-dir> <project-name> [<excluded-login>]
# Prints the profile the usage rule above chooses, or nothing when this
# machine has no named profile with an Anthropic login. On refusal prints one
# error and returns 1.
fm_omp_profile_pick() {
  local config=$1 project=$2 exclude=${3:-} list logins ranked restricted=0 picked
  [ -n "$(find "$(fm_omp_root)/profiles" -mindepth 3 -maxdepth 3 -name agent.db 2>/dev/null | head -n 1)" ] || return 0
  list=$(fm_account_rules_list 2>/dev/null) || list='{"schemaVersion":1,"accounts":[]}'
  logins=$(fm_omp_profile_logins "$list")
  [ -n "$logins" ] || return 0
  ranked=$(fm_account_rules_ranked "$config" "$project" "$list") || return 1
  # A project line is an allowlist of cswap accounts, which an unlisted login
  # can never satisfy.
  if [ -e "$config/account-rules" ] && fm_account_rules_parse "$config/account-rules" \
      | awk -v p="$project" '$1 == "project" && tolower($2) == tolower(p) { found = 1 } END { exit !found }'; then
    restricted=1
  fi
  picked=$(awk -F'\t' -v ranked="$(printf '%s' "$ranked" | tr '\n' ' ')" -v out="$(fm_login_exhausted_list | tr '\n' ' ')" \
      -v exclude="$exclude" -v restricted="$restricted" '
    BEGIN {
      n = split(ranked, r, " ")
      for (i = 1; i < n; i += 2) rank["cswap:" r[i]] = r[i + 1]
      m = split(out, o, " ")
      for (i = 1; i <= m; i++) gone[o[i]] = 1
    }
    $2 == exclude || ($2 in gone) { next }
    $2 ~ /^cswap:/ { if ($2 in rank) print rank[$2] "\t" $1; next }
    restricted == 0 { print 1001 "\t" $1 }
  ' <<<"$logins" | sort -t $'\t' -k1,1n -k2,2 | head -n 1 | cut -f2)
  if [ -z "$picked" ]; then
    echo "error: no omp profile under $(fm_omp_root)/profiles has a login with usage left for '$project' (rules, usage, and exhausted logins in $(fm_login_exhausted_file) leave none${exclude:+ besides $exclude}); refusing to launch on an exhausted login" >&2
    return 1
  fi
  printf '%s\n' "$picked"
}

# fm_omp_profile_select <harness> <config-dir> <secondmate-id> [<raw-command>] [<project-name>]
# The whole launch-time decision. Prints nothing when no profile applies: a
# harness other than omp, an unpinned raw command, or a machine with no named
# profile. Otherwise prints "<profile><TAB><pin|usage>". On refusal prints one
# error and returns 1. bin/fm-spawn.sh runs it before any endpoint exists, and
# bin/fm-control.sh before a relaunch stops the live agent.
fm_omp_profile_select() {
  local harness=$1 config=$2 mate=${3:-} raw=${4:-} project=${5:-} cfg name rc login picked
  [ "$harness" = omp ] || return 0
  if [ -n "$mate" ]; then
    cfg="$config/secondmate-accounts/$mate/omp-profile"
    name=$(fm_omp_profile_read "$cfg")
    rc=$?
  else
    rc=3
  fi
  case "$rc" in
  0) ;;
  3)
    [ -z "$raw" ] || return 0
    picked=$(fm_omp_profile_pick "$config" "$project") || return 1
    [ -z "$picked" ] || printf '%s\tusage\n' "$picked"
    return 0
    ;;
  4) return 1 ;;
  5)
    echo "error: $cfg must be a readable regular file" >&2
    return 1
    ;;
  *)
    echo "error: $cfg must hold one omp profile name on a single line, matching ^[a-z0-9][a-z0-9._-]{0,63}\$, not ending in '.', and not a Windows reserved device name (con, prn, aux, nul, com0-9, lpt0-9, alone or with an extension), with no other lines or control characters" >&2
    return 1
    ;;
  esac
  if [ -n "$raw" ]; then
    echo "error: $cfg pins secondmate $mate to omp profile $name, and a raw omp launch command runs verbatim, so it cannot carry --profile; launch with --harness omp instead, or remove $cfg" >&2
    return 1
  fi
  login=$(fm_omp_profile_login "$name" "$(fm_account_rules_list 2>/dev/null)")
  if fm_login_exhausted_list | grep -qxF "$login"; then
    picked=$(fm_omp_profile_pick "$config" "$project" "$login") || return 1
    if [ -n "$picked" ]; then
      echo "notice: $cfg pins omp profile $name, whose login $login is recorded exhausted; launching on $picked by usage instead" >&2
      printf '%s\tusage\n' "$picked"
      return 0
    fi
  fi
  printf '%s\tpin\n' "$name"
}

# fm_omp_session_file <state-dir> <task-id>
# Prints the omp session file the task's live agent last reported through its
# spawn-written extension (state/<id>.omp-session), when that file exists.
# A seat spawned before that record existed falls back to the newest session in
# omp's own folder for its profile and working directory: omp keeps sessions
# under <profile>/agent/sessions/<cwd relative to HOME, with / as ->, a layout
# tests/fm-exhaust-switch-omp-live-e2e.test.sh checks on the installed omp.
fm_omp_session_file() {
  local f x meta="$1/$2.meta" wt profile dir
  if [ -f "$1/$2.omp-session" ]; then
    f=$(head -n 1 "$1/$2.omp-session")
    case "$f" in /*.jsonl) [ -f "$f" ] && printf '%s\n' "$f" ;; *) return 1 ;; esac
    return
  fi
  [ -f "$meta" ] || return 1
  wt=$(sed -n 's/^worktree=//p' "$meta" | tail -n 1)
  [ -n "$wt" ] || return 1
  profile=$(sed -n 's/^omp_profile=//p' "$meta" | tail -n 1)
  dir="$(fm_omp_root)${profile:+/profiles/$profile}/agent/sessions/$(printf '%s' "${wt#"${HOME%/}"}" | tr '/' '-')"
  f=
  for x in "$dir"/*.jsonl; do
    [ -f "$x" ] || continue
    [ -n "$f" ] && [ ! "$x" -nt "$f" ] || f=$x
  done
  [ -n "$f" ] && printf '%s\n' "$f"
}

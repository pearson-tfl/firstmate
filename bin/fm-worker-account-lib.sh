#!/usr/bin/env bash
# fm-worker-account-lib.sh - the single owner of the opt-in per-home worker
# and per-secondmate account pins: which runners can be pinned, how a pin file
# is parsed and resolved, the launch-time sign-in check under it, and the
# environment credentials a pinned Claude launch sheds.
#
# docs/configuration.md "Worker account pin" owns the operator-facing contract.
# Sourced by bin/fm-spawn.sh and bin/fm-control.sh.
#
# Pinnable runners, each a credential store inside a root its vendor lets a
# process select:
#   claude          CLAUDE_CONFIG_DIR     config/claude-account
#   pi, pi-signed   PI_CODING_AGENT_DIR   config/pi-account
#
# The pin is opt-in: an absent file is no pin, and the launch keeps today's
# ambient behavior byte for byte. A present file must resolve, or the launch
# refuses; nothing falls back to an ambient or vendor-default login once a
# home has declared one. `ordinary` selects the vendor default: for Claude
# that is CLAUDE_CONFIG_DIR unset, because Claude reads $CLAUDE_CONFIG_DIR/
# .claude.json and keys its macOS Keychain entry to any CLAUDE_CONFIG_DIR that
# is set, even $HOME/.claude; for Pi it is $HOME/.pi/agent. Any other value is
# one absolute path to an existing readable, searchable directory. Firstmate
# never copies credentials or changes a global login.
#
# A Pi root can hold several provider identities, so config/pi-account names
# the root on line 1 and the providers that home may spend on line 2,
# separated by spaces. A pinned Pi launch must name its provider explicitly as
# --model <provider>/<id>, and that provider must be declared; Firstmate never
# guesses a provider for an unqualified model. The canonical launch also
# passes --provider <that provider>, because without it Pi may resolve a
# provider-prefixed model under another authenticated provider. A raw Pi
# launch command is launched verbatim and cannot receive that flag, so a home
# with config/pi-account refuses raw Pi launches. A raw Claude launch command
# runs after the pinned root and shed credentials are applied, so its own
# leading CLAUDE_CONFIG_DIR or shed-credential assignment would override the
# pin; a home with config/claude-account refuses such a command.
#
# The sign-in check asks the runner itself, with only HOME, PATH, TMPDIR,
# USER, LOGNAME, and the selected root in its environment, so a credential
# variable left in the caller cannot answer for a root that has no login:
#   Claude: `claude auth status`, which exits 0 only when signed in.
#   Pi:     `pi auth check --provider <p> --json --no-refresh`; status "ready"
#           passes. `pi auth check` loads no extensions, so it answers
#           not_ready/provider_not_found for an extension-registered provider,
#           and a Pi without the command (before 0.84.1) prints no JSON. Both
#           fall through to `pi --list-models <p>`, which lists only the models
#           a root can authenticate; a row whose provider column is exactly
#           <p> passes. --no-refresh keeps the check from rewriting a root's
#           tokens while other workers use them.
# A pinned Claude launch also unsets the environment credentials Claude ranks
# above the root's stored login, so an ambient API key or token cannot outrank
# the pin. Pi ranks a root's stored credentials above environment variables,
# and the check refuses a provider the root has not stored, so a pinned Pi
# launch unsets nothing.

# shellcheck source=bin/fm-timeout-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"

FM_WORKER_ACCOUNT_CHECK_SECONDS=${FM_WORKER_ACCOUNT_CHECK_SECONDS:-30}

# Credentials Claude Code ranks above the /login stored in its config root
# (code.claude.com/docs/en/authentication, "Authentication precedence"; the
# Claude Platform on AWS and Bedrock Mantle switches from
# code.claude.com/docs/en/env-vars).
FM_WORKER_ACCOUNT_CLAUDE_SHED="CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY CLAUDE_CODE_USE_ANTHROPIC_AWS CLAUDE_CODE_USE_MANTLE ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_PROFILE ANTHROPIC_FEDERATION_RULE_ID"

# fm_worker_account_file <harness>
# Prints the pin file name for a pinnable runner; returns 1 for any other.
fm_worker_account_file() {
  case "$1" in
  claude) printf '%s\n' claude-account ;;
  pi | pi-signed) printf '%s\n' pi-account ;;
  *) return 1 ;;
  esac
}

# fm_worker_account_read <harness> <file>
# Prints "declared<TAB>providers" for a valid pin, where declared is
# `ordinary` or the absolute path and providers is empty for Claude. The final
# newline is optional; any other control byte, including a CR, is malformed.
# Parses bytes before the shell can drop NULs or trailing newlines; paths are
# literal, never shell expressions. Returns 0 on success, 3 when the file does
# not exist, 4 when it cannot be inspected (one error already printed), 5 when
# it is not a readable regular file, and 6 when it is malformed.
fm_worker_account_read() {
  perl -MErrno=ENOENT -e '
    my ($harness, $f) = @ARGV;
    unless (lstat $f) {
      exit 3 if $! == ENOENT;
      print STDERR "error: cannot inspect configuration source at $f: $!\n";
      exit 4;
    }
    (-f $f && -r _) or exit 5;
    open(my $fh, "<", $f) or exit 5;
    my $body = do { local $/; <$fh> } // "";
    if ($harness eq "claude") {
      $body =~ /\A(ordinary|\/[^\x00-\x1f\x7f]*)\n?\z/ or exit 6;
      print $1, "\t";
    } else {
      $body =~ /\A(ordinary|\/[^\x00-\x1f\x7f]*)\n([A-Za-z0-9][A-Za-z0-9._-]*(?: +[A-Za-z0-9][A-Za-z0-9._-]*)*)\n?\z/ or exit 6;
      print $1, "\t", $2;
    }
  ' -- "$1" "$2"
}

# fm_worker_account_config <harness> <config-dir> [<secondmate-id>]
# Prints the directory containing the applicable pin. Only a missing per-mate
# file falls back to the home pin; unreadable or malformed files still select
# the override so the ordinary parser refuses them. Non-pinnable runners and
# ordinary workers keep the supplied directory unchanged.
fm_worker_account_config() {
  local harness=$1 config=$2 mate=${3:-} file candidate rc
  if [ -z "$mate" ] || ! file=$(fm_worker_account_file "$harness"); then
    printf '%s\n' "$config"
    return 0
  fi
  candidate="$config/secondmate-accounts/$mate"
  fm_worker_account_read "$harness" "$candidate/$file" >/dev/null
  rc=$?
  case "$rc" in
  3) printf '%s\n' "$config" ;;
  4) return 1 ;;
  *) printf '%s\n' "$candidate" ;;
  esac
}

# fm_worker_account_resolve <harness> <config-dir> <setting>
# Prints "declared<TAB>root<TAB>providers" for a valid pin, where root is the
# directory the launch selects (empty for ordinary Claude, meaning
# CLAUDE_CONFIG_DIR unset). Prints nothing and returns 0 when the runner is
# not pinnable or the home has no pin. On refusal prints one error naming the
# file and returns 1.
fm_worker_account_resolve() {
  local harness=$1 config=$2 setting=$3 file cfg token rc declared root fallback
  file=$(fm_worker_account_file "$harness") || return 0
  cfg="$config/$file"
  token=$(fm_worker_account_read "$harness" "$cfg")
  rc=$?
  case "$rc" in
  0) ;;
  3) return 0 ;;
  4) return 1 ;;
  5)
    echo "error: $setting must be a readable regular file: $cfg" >&2
    return 1
    ;;
  *)
    if [ "$file" = pi-account ]; then
      echo "error: $setting must hold 'ordinary' or one absolute path on line 1 and the providers this home may spend on line 2, separated by spaces, with no other lines or control characters: $cfg" >&2
    else
      echo "error: $setting must hold 'ordinary' or one absolute path on a single line with no control characters: $cfg" >&2
    fi
    return 1
    ;;
  esac
  declared=${token%%$'\t'*}
  root=$declared
  # shellcheck disable=SC2088  # The fallbacks are literal text for the refusal.
  case "$harness" in
  claude) fallback='~/.claude with CLAUDE_CONFIG_DIR unset' ;;
  *) fallback='~/.pi/agent' ;;
  esac
  if [ "$declared" = ordinary ]; then
    case "$harness" in
    claude) root= ;;
    *) root="${HOME:?HOME is required to resolve an ordinary Pi account}/.pi/agent" ;;
    esac
  fi
  if [ -n "$root" ] && { [ ! -d "$root" ] || [ ! -r "$root" ] || [ ! -x "$root" ]; }; then
    echo "error: $setting must name a readable, searchable existing directory (ordinary means $fallback): $cfg -> $root" >&2
    return 1
  fi
  printf '%s\t%s\t%s\n' "$declared" "$root" "${token#*$'\t'}"
}

# fm_worker_account_pi_provider <model>
# Prints the provider an explicit Pi --model <provider>/<id> names. Returns 1,
# silently, for anything else, so no caller can fall back to a guess.
fm_worker_account_pi_provider() {
  local model=$1
  case "$model" in
  */*)
    [ -n "${model%%/*}" ] && [ -n "${model#*/}" ] || return 1
    printf '%s\n' "${model%%/*}"
    ;;
  *) return 1 ;;
  esac
}

# fm_worker_account_check <harness> <declared> <root> <executable> [<provider>] [<setting>]
# Returns 0 only when the runner's own check says the selected root is signed
# in for this launch; otherwise prints one error and returns 1.
fm_worker_account_check() {
  local harness=$1 declared=$2 root=$3 executable=$4 provider=${5:-} setting=${6:-} out verdict name
  [ -n "$setting" ] || setting="config/$(fm_worker_account_file "$harness")"
  local -a clean=(env -i "HOME=${HOME:-}" "PATH=${PATH:-}")
  for name in TMPDIR USER LOGNAME; do
    [ -z "${!name:-}" ] || clean+=("$name=${!name}")
  done
  case "$harness" in
  claude)
    [ -z "$root" ] || clean+=("CLAUDE_CONFIG_DIR=$root")
    if fm_run_timed "$FM_WORKER_ACCOUNT_CHECK_SECONDS" "${clean[@]}" \
      "$executable" auth status >/dev/null 2>&1 </dev/null; then
      return 0
    fi
    if [ -n "$root" ]; then
      echo "error: $setting pins Claude workers to $root, which is not signed in (claude auth status); sign in with CLAUDE_CONFIG_DIR=$root claude, then /login, or change the pin" >&2
    else
      echo "error: $setting pins Claude workers to the ordinary account, which is not signed in (claude auth status); sign in with env -u CLAUDE_CONFIG_DIR claude, then /login, or change the pin" >&2
    fi
    return 1
    ;;
  pi | pi-signed)
    clean+=("PI_CODING_AGENT_DIR=$root")
    out=$(fm_run_timed "$FM_WORKER_ACCOUNT_CHECK_SECONDS" "${clean[@]}" \
      "$executable" auth check --provider "$provider" --json --no-refresh 2>/dev/null </dev/null)
    verdict=$(printf '%s\n' "$out" | jq -r '
      if type != "object" or (has("status") | not) then "list"
      elif .status == "ready" then "ready"
      elif .status == "not_ready" and .reason == "provider_not_found" then "list"
      else "\(.status) \(.reason // "")"
      end' 2>/dev/null)
    case "${verdict:-list}" in
    ready) return 0 ;;
    list)
      if out=$(fm_run_timed "$FM_WORKER_ACCOUNT_CHECK_SECONDS" "${clean[@]}" \
        "$executable" --list-models "$provider" 2>/dev/null </dev/null) &&
        printf '%s\n' "$out" | awk -v p="$provider" 'NR > 1 && $1 == p { found = 1; exit } END { exit !found }'; then
        return 0
      fi
      verdict="no model listed for provider $provider"
      ;;
    esac
    echo "error: $setting pins Pi workers to $declared, which is not signed in for provider '$provider' ($verdict); sign in with PI_CODING_AGENT_DIR=$root $harness, then /login, or change the pin" >&2
    return 1
    ;;
  esac
  return 0
}

# fm_worker_account_select <harness> <config-dir> <model> <executable> [<raw-command>] [<secondmate-id>] [<project-name>]
# The whole launch-time decision. A Claude launch from a home with
# config/account-rules chooses through cswap (fm_account_rules_resolve) and
# then passes the same raw-command guard and sign-in check as a pin. Prints nothing for an unpinned runner, so
# the caller keeps today's launch unchanged. For a pinned one prints
# "declared<TAB>root<TAB>provider", where provider is the Pi launch model's
# own (empty for Claude), after the model guard and the sign-in check pass. On
# refusal prints one error and returns 1. bin/fm-spawn.sh runs it before any
# endpoint exists, and bin/fm-control.sh before a relaunch stops the live
# agent.
fm_worker_account_select() {
  local harness=$1 config=$2 model=$3 executable=$4 raw=${5:-} mate=${6:-} project=${7:-}
  local selection declared root providers word provider='' selected_config setting
  selected_config=$(fm_worker_account_config "$harness" "$config" "$mate") || return 1
  setting="config/$(fm_worker_account_file "$harness")"
  [ "$selected_config" = "$config" ] || setting="$selected_config/$(fm_worker_account_file "$harness")"
  if [ "$harness" = claude ] && { [ -e "$config/account-rules" ] || [ -L "$config/account-rules" ] ||
    [ -e "$config/account-rules.approved" ] || [ -L "$config/account-rules.approved" ]; }; then
    setting=config/account-rules
    selection=$(fm_account_rules_resolve "$config" "$project" "$executable" "$selected_config") || return 1
  else
    selection=$(fm_worker_account_resolve "$harness" "$selected_config" "$setting") || return 1
  fi
  if [ -z "$selection" ]; then
    [ "$selected_config" = "$config" ] && return 0
    echo "error: secondmate account pin disappeared during selection: $setting" >&2
    return 1
  fi
  declared=${selection%%$'\t'*}
  root=${selection#*$'\t'}
  providers=${root#*$'\t'}
  root=${root%%$'\t'*}
  if [ "$harness" = claude ]; then
    for word in $raw; do
      case "$word" in
      [A-Za-z_]*=*)
        case " CLAUDE_CONFIG_DIR $FM_WORKER_ACCOUNT_CLAUDE_SHED " in
        *" ${word%%=*} "*)
          echo "error: $setting pins Claude workers, but the raw launch command sets ${word%%=*}, which would override the pinned account; remove ${word%%=*} from the raw command, or change or remove $setting" >&2
          return 1
          ;;
        esac
        ;;
      *) break ;;
      esac
    done
  else
    if [ -n "$raw" ]; then
      echo "error: $setting pins Pi workers, and a raw Pi launch command runs verbatim, so it cannot carry the pinned --provider; launch with --harness $harness and --model <provider>/<id> instead" >&2
      return 1
    fi
    provider=$(fm_worker_account_pi_provider "$model") || {
      echo "error: $setting pins Pi workers to providers ($providers), so a Pi launch needs --model <provider>/<id> naming one of them; '${model:-none}' names no provider, and Firstmate does not guess one" >&2
      return 1
    }
    case " $providers " in
    *" $provider "*) ;;
    *)
      echo "error: $setting pins Pi workers to providers ($providers), but --model '$model' names provider '$provider'" >&2
      return 1
      ;;
    esac
  fi
  fm_worker_account_check "$harness" "$declared" "$root" "$executable" "$provider" "$setting" || return 1
  printf '%s\t%s\t%s\n' "$declared" "$root" "$provider"
}

# fm_worker_account_claude_shed
# Prints the `env` launch prefix that unsets the environment credentials Claude
# ranks above a pinned root's stored login. The caller appends the root
# assignment, or -u CLAUDE_CONFIG_DIR for the ordinary account.
fm_worker_account_claude_shed() {
  local var prefix=env
  for var in $FM_WORKER_ACCOUNT_CLAUDE_SHED; do
    prefix="$prefix -u $var"
  done
  printf '%s\n' "$prefix"
}

# --- Rules-based Claude account selection through cswap -------------------
# docs/configuration.md "Account rules" owns the operator-facing contract.
#
# config/account-rules, when present, replaces config/claude-account for every
# Claude launch from this home: a pin file beside it refuses rather than being
# used. Each line is blank, a # comment, or one directive, with cswap account
# numbers as the only account names:
#   forbid <num>...              never choose these accounts
#   project <name> <num>...      tasks on project <name> (the project
#                                directory's own name, compared without
#                                regard to case) choose only from these
# A project with no line chooses from every cswap account. A forbid always
# wins over a project line.
#
# The file is John's. config/account-rules.approved holds the SHA-256 of the
# exact bytes he approved through `bin/fm-account-rules.sh approve`, which
# reads his confirmation from the controlling terminal; a missing or stale
# fingerprint refuses every Claude launch until he approves the current file,
# and so does a rules file removed while its approval remains: retiring the
# rules means removing config/account-rules.approved as well.
#
# The choice reads `cswap list --json` (schemaVersion 1): among the allowed
# accounts, the lowest of each account's highest five-hour or seven-day usage
# percentage wins, ties going to the lower number; an account at 100 percent
# or more is skipped, and an account whose usage cswap cannot report ranks
# after every measured one. `cswap run <num>` then prepares that account's own
# profile root and execs the `claude` on PATH; a probe `claude` placed first on
# PATH records the root it receives (empty when cswap runs the account that is
# already the default login) and hands every other claude call cswap makes,
# such as its own `auth status` profile check, to the real claude. The launch
# then runs on that root exactly as a pinned one does. Firstmate never runs
# `cswap switch`, so the global login and every saved token stay as they were.
#
# Every account choice a spawn or relaunch makes appends one report line to
# data/account-switches.log (fm_account_rules_report).

FM_ACCOUNT_RULES_CSWAP_SECONDS=${FM_ACCOUNT_RULES_CSWAP_SECONDS:-60}

# fm_account_rules_fingerprint <file>
# Prints the SHA-256 hex digest of the file's bytes.
fm_account_rules_fingerprint() {
  local digest
  if command -v shasum >/dev/null 2>&1; then
    digest=$(shasum -a 256 < "$1") || return 1
  else
    digest=$(sha256sum < "$1") || return 1
  fi
  printf '%s\n' "${digest%% *}"
}

# fm_account_rules_parse <file>
# Validates the rules file and prints its directives, one per line, with
# comments and blank lines dropped. On a malformed line prints one error
# naming the line and returns 1.
fm_account_rules_parse() {
  perl -e '
    my $f = shift;
    open(my $fh, "<", $f) or do { print STDERR "error: cannot read account rules $f: $!\n"; exit 1 };
    my (%project, $n);
    while (my $line = <$fh>) {
      $n++;
      chomp $line;
      next if $line =~ /\A\s*(#.*)?\z/;
      if ($line =~ /\A\s*forbid((?:\s+[1-9][0-9]*)+)\s*\z/) {
        print "forbid", join(" ", "", split(" ", $1)), "\n";
      } elsif ($line =~ /\A\s*project\s+([A-Za-z0-9][A-Za-z0-9._-]*)((?:\s+[1-9][0-9]*)+)\s*\z/) {
        if ($project{lc $1}++) {
          print STDERR "error: config/account-rules line $n repeats project $1; give each project one line\n";
          exit 1;
        }
        print "project $1", join(" ", "", split(" ", $2)), "\n";
      } else {
        print STDERR "error: config/account-rules line $n is not \"forbid <num>...\" or \"project <name> <num>...\": $line\n";
        exit 1;
      }
    }
  ' -- "$1"
}

# fm_account_rules_approved <config-dir>
# Returns 0 when config/account-rules.approved holds the fingerprint of the
# current rules file; otherwise prints one error and returns 1.
fm_account_rules_approved() {
  local config=$1 want have
  have=$(fm_account_rules_fingerprint "$config/account-rules") || {
    echo "error: cannot fingerprint config/account-rules" >&2
    return 1
  }
  want=$(cat "$config/account-rules.approved" 2>/dev/null) || want=
  if [ "$want" != "$have" ]; then
    echo "error: config/account-rules has changed since John approved it, so no Claude worker launches until he does; John runs bin/fm-account-rules.sh approve at a terminal" >&2
    return 1
  fi
}

# fm_account_rules_pick <config-dir> <project-name>
# Prints the cswap account number the approved rules choose for the project.
# On refusal prints one error and returns 1.
fm_account_rules_pick() {
  local config=$1 project=$2 rules forbidden='' allowed='' list picked line name want
  rules=$(fm_account_rules_parse "$config/account-rules") || return 1
  want=$(printf '%s' "$project" | tr '[:upper:]' '[:lower:]')
  while IFS= read -r line; do
    case "$line" in
    "forbid "*) forbidden="$forbidden ${line#forbid }" ;;
    "project "*)
      name=${line#project }
      name=${name%% *}
      [ "$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')" != "$want" ] ||
        allowed=${line#"project $name "}
      ;;
    esac
  done <<<"$rules"
  list=$(fm_run_timed "$FM_ACCOUNT_RULES_CSWAP_SECONDS" cswap list --json 2>/dev/null </dev/null) || {
    echo "error: config/account-rules needs cswap's account list, but cswap list --json failed; check that cswap is installed and on PATH" >&2
    return 1
  }
  picked=$(printf '%s\n' "$list" | jq -r \
    --arg forbidden "$forbidden" --arg allowed "$allowed" '
    if .schemaVersion != 1 then error("schema") else . end
    | ($forbidden | split(" ") | map(select(. != "") | tonumber)) as $no
    | ($allowed | split(" ") | map(select(. != "") | tonumber)) as $only
    | [ .accounts[]
        | select((.number | IN($no[])) | not)
        | select(($only | length) == 0 or (.number | IN($only[])))
        | { n: .number,
            u: (if .usageStatus == "ok"
                then ([.usage.fiveHour.pct?, .usage.sevenDay.pct?] | map(select(type == "number")) | max)
                else null end) }
        | .rank = (.u // 1000)
        | select(.rank < 100 or .u == null) ]
    | sort_by(.rank, .n) | .[0].n // empty' 2>/dev/null) || {
    echo "error: config/account-rules needs cswap's account list in schemaVersion 1, and cswap list --json printed something else" >&2
    return 1
  }
  if [ -z "$picked" ]; then
    echo "error: config/account-rules allows no cswap account with headroom for project '$project' (forbidden:${forbidden:- none}; allowed: ${allowed:-every account})" >&2
    return 1
  fi
  printf '%s\n' "$picked"
}

# fm_account_rules_profile <num> <claude-executable>
# Prints the Claude config root `cswap run <num>` launches that account on,
# empty when it is the default login. On failure prints one error, return 1.
fm_account_rules_profile() {
  local num=$1 executable=$2 real probe rc name
  real=$(command -v "$executable") || {
    echo "error: config/account-rules launches Claude through cswap, but $executable is not on PATH" >&2
    return 1
  }
  probe=$(mktemp -d "${TMPDIR:-/tmp}/fm-cswap-probe.XXXXXX") || return 1
  # shellcheck disable=SC2016  # The probe's own expansions run inside it.
  {
    printf '#!/usr/bin/env bash\n'
    printf 'if [ "$#" -gt 0 ]; then exec %q "$@"; fi\n' "$real"
    printf 'printf %%s "${CLAUDE_CONFIG_DIR-}" > %q\n' "$probe/root"
  } > "$probe/claude"
  chmod +x "$probe/claude"
  local -a clean=(env -i "HOME=${HOME:-}" "PATH=$probe:${PATH:-}")
  for name in TMPDIR USER LOGNAME; do
    [ -z "${!name:-}" ] || clean+=("$name=${!name}")
  done
  fm_run_timed "$FM_ACCOUNT_RULES_CSWAP_SECONDS" "${clean[@]}" cswap run "$num" \
    >/dev/null 2>"$probe/err" </dev/null
  rc=$?
  if [ "$rc" -ne 0 ] || [ ! -f "$probe/root" ]; then
    echo "error: config/account-rules chose cswap account $num, but cswap run $num did not launch it (exit $rc): $(tail -n 1 "$probe/err" 2>/dev/null)" >&2
    rm -rf "$probe"
    return 1
  fi
  cat "$probe/root"
  rm -rf "$probe"
}

# fm_account_rules_resolve <config-dir> <project-name> <claude-executable> <pin-config-dir>
# The rules counterpart of fm_worker_account_resolve: prints
# "cswap:<num><TAB>root<TAB>" or prints one error and returns 1. Refuses when
# a Claude pin file is present in <pin-config-dir>, because the rules replace it.
fm_account_rules_resolve() {
  local config=$1 project=$2 executable=$3 pin_config=$4 num root
  if [ -e "$pin_config/claude-account" ] || [ -L "$pin_config/claude-account" ]; then
    echo "error: config/account-rules replaces the per-home Claude account setting, so $pin_config/claude-account must be removed" >&2
    return 1
  fi
  if [ ! -e "$config/account-rules" ] && [ ! -L "$config/account-rules" ]; then
    echo "error: config/account-rules was removed while John's approval of it remains, so no Claude worker launches; John retires the rules by removing config/account-rules.approved too" >&2
    return 1
  fi
  fm_account_rules_approved "$config" || return 1
  num=$(fm_account_rules_pick "$config" "$project") || return 1
  root=$(fm_account_rules_profile "$num" "$executable") || return 1
  printf 'cswap:%s\t%s\t\n' "$num" "$root"
}

# fm_account_rules_report <data-dir> <task-id> <from> <to>
# Appends and prints the one report line for an account choice; from is the
# task's previous account, or none.
fm_account_rules_report() {
  local data=$1 id=$2 from=$3 to=$4 line
  line="$(date -u +%Y-%m-%dT%H:%M:%SZ) task=$id from=$from to=$to"
  if ! { mkdir -p "$data" && printf '%s\n' "$line" >> "$data/account-switches.log"; }; then
    echo "warning: could not append the account report line to $data/account-switches.log: $line" >&2
    return 0
  fi
  printf 'account-switch: %s\n' "$line"
}

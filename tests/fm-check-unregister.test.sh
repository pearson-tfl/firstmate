#!/usr/bin/env bash
# Behavior tests for fm-check-unregister.sh: resolve state via FM_STATE_OVERRIDE
# and FM_HOME, refuse invalid ids and unsafe paths, and remove only the named
# custom-check files on the happy path.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

UNREGISTER="$ROOT/bin/fm-check-unregister.sh"
REGISTER="$ROOT/bin/fm-check-register.sh"
TMP_ROOT=$(fm_test_tmproot fm-check-unregister)
REAL_RM=$(command -v rm)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

write_check_script() {
  local path=$1
  cat > "$path" <<'SH'
#!/usr/bin/env bash
printf 'custom-ready\n'
SH
  chmod 0700 "$path"
}

write_registered_check_in_state() {
  local state_dir=$1 id=$2
  write_check_script "$state_dir/$id.check.sh"
  env -u STATE -u FM_HOME FM_STATE_OVERRIDE="$state_dir" "$REGISTER" "$id" >/dev/null \
    || fail "could not register custom check $id in $state_dir"
}

write_registered_check() {
  local home=$1 id=$2
  write_check_script "$home/state/$id.check.sh"
  FM_HOME="$home" "$REGISTER" "$id" >/dev/null \
    || fail "could not register custom check $id"
}

install_rm_logger() {
  local home=$1 fakebin log
  fakebin=$(fm_fakebin "$home")
  log="$home/rm.log"
  : > "$log"
  cat > "$fakebin/rm" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
exec "$REAL_RM" "\$@"
SH
  chmod +x "$fakebin/rm"
  printf '%s\n' "$log"
}

assert_rm_not_invoked() {
  local log=$1
  [ -s "$log" ] && fail "retire path invoked rm while refusing"$'\n'"--- rm log ---"$'\n'"$(cat "$log")"
}

test_empty_id_and_empty_state_refuse_without_stray_rm() {
  local home out err status log canary_empty_id canary_sibling decoy
  home=$(make_home empty-var)
  out="$home/out.txt"
  err="$home/err.txt"
  log=$(install_rm_logger "$home")
  canary_empty_id="$home/state/.check.sh"
  canary_sibling="$home/state/keep.check.sh"
  decoy="$home/decoy.check.sh"
  printf 'canary-empty-id\n' > "$canary_empty_id"
  printf 'sibling\n' > "$canary_sibling"
  printf 'decoy\n' > "$decoy"
  chmod 0700 "$canary_empty_id" "$canary_sibling"

  status=0
  PATH="$home/fakebin:$PATH" STATE='' ID='' FM_HOME="$home" \
    "$UNREGISTER" >"$out" 2>"$err" || status=$?
  expect_code 2 "$status" "unregister with no id"
  assert_contains "$(cat "$err")" "error:" "missing-id refusal had no stderr"
  assert_present "$canary_empty_id" "empty-id expansion deleted state/.check.sh"
  assert_present "$canary_sibling" "missing-id call deleted a sibling check file"
  assert_present "$decoy" "missing-id call deleted a decoy outside state/"
  assert_rm_not_invoked "$log"

  status=0
  : > "$log"
  PATH="$home/fakebin:$PATH" STATE='' ID='' FM_HOME="$home" \
    "$UNREGISTER" "" >"$out" 2>"$err" || status=$?
  expect_code 2 "$status" "unregister with empty id"
  assert_contains "$(cat "$err")" "error:" "empty-id refusal had no stderr"
  assert_present "$canary_empty_id" "empty-string id deleted state/.check.sh"
  assert_rm_not_invoked "$log"

  status=0
  : > "$log"
  PATH="$home/fakebin:$PATH" STATE='' ID='' FM_HOME="$home" \
    "$UNREGISTER" "../escape" >"$out" 2>"$err" || status=$?
  expect_code 2 "$status" "unregister with unsafe id"
  assert_present "$canary_empty_id" "unsafe id deleted state/.check.sh"
  assert_rm_not_invoked "$log"

  mkdir -p "$home/nostate-home"
  printf 'pre-state-canary\n' > "$home/nostate-home/.check.sh"
  status=0
  : > "$log"
  PATH="$home/fakebin:$PATH" STATE='' ID='' FM_STATE_OVERRIDE='' \
    FM_HOME="$home/nostate-home" \
    "$UNREGISTER" demo-check >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "unregister with missing state dir"
  assert_contains "$(cat "$err")" "state directory is unavailable" \
    "missing state dir refusal used the wrong stderr"
  assert_present "$home/nostate-home/.check.sh" \
    "missing-state-dir call deleted a stray path in the home"
  assert_present "$canary_empty_id" "missing-state-dir call reached another home's files"
  assert_rm_not_invoked "$log"

  status=0
  : > "$log"
  PATH="$home/fakebin:$PATH" STATE='' ID='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/missing-state" \
    "$UNREGISTER" demo-check >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "unregister with empty-equivalent state override"
  assert_contains "$(cat "$err")" "state directory is unavailable" \
    "non-directory state override refusal used the wrong stderr"
  assert_present "$canary_empty_id" "bad state override deleted state/.check.sh"
  assert_present "$canary_sibling" "bad state override deleted a sibling"
  assert_rm_not_invoked "$log"

  write_registered_check "$home" symlink-override
  ln -s "$home/state" "$home/state-symlink"
  status=0
  : > "$log"
  PATH="$home/fakebin:$PATH" env -u STATE FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state-symlink" \
    "$UNREGISTER" symlink-override >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "unregister with symlinked state override"
  assert_contains "$(cat "$err")" "state directory is unavailable" \
    "symlinked state override refusal used the wrong stderr"
  assert_present "$home/state/symlink-override.check.sh" \
    "symlinked state override deleted the target state check"
  assert_present "$home/state/symlink-override.check-trust" \
    "symlinked state override deleted the target state trust binding"
  assert_rm_not_invoked "$log"

  pass "empty id, missing state dir, or symlinked state dir refuses loudly and never rms a stray path"
}

test_happy_path_removes_only_check_and_trust() {
  local home decoy_state out err status sibling meta
  home=$(make_home happy)
  decoy_state="$home/decoy-state"
  mkdir -p "$decoy_state"
  out="$home/out.txt"
  err="$home/err.txt"
  sibling="$home/state/other.check.sh"
  meta="$home/state/demo-check.meta"
  write_registered_check "$home" demo-check
  write_registered_check "$home" caller-state-check
  write_registered_check_in_state "$decoy_state" caller-state-check
  printf '#!/usr/bin/env bash\nprintf other\n' > "$sibling"
  chmod 0700 "$sibling"
  printf 'keep-meta\n' > "$meta"
  assert_present "$home/state/demo-check.check.sh" "fixture check.sh missing before unregister"
  assert_present "$home/state/demo-check.check-trust" "fixture check-trust missing before unregister"

  status=0
  STATE='' ID='' FM_HOME="$home" "$UNREGISTER" demo-check >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "happy-path unregister"
  assert_contains "$(cat "$out")" "unregistered: state/demo-check.check.sh" \
    "happy path did not report unregistration"
  assert_absent "$home/state/demo-check.check.sh" "happy path left check.sh behind"
  assert_absent "$home/state/demo-check.check-trust" "happy path left check-trust behind"
  assert_present "$sibling" "happy path deleted a sibling check.sh"
  assert_present "$meta" "happy path deleted an unrelated state file"

  status=0
  env -u FM_STATE_OVERRIDE STATE="$decoy_state" FM_HOME="$home" \
    "$UNREGISTER" caller-state-check >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "caller passing STATE behaves as before"
  assert_contains "$(cat "$out")" "unregistered: state/caller-state-check.check.sh" \
    "caller-STATE unregister did not report unregistration"
  assert_absent "$home/state/caller-state-check.check.sh" \
    "caller-STATE unregister did not remove FM_HOME/state check.sh"
  assert_absent "$home/state/caller-state-check.check-trust" \
    "caller-STATE unregister did not remove FM_HOME/state check-trust"
  assert_present "$decoy_state/caller-state-check.check.sh" \
    "caller-STATE unregister touched caller STATE instead of FM_HOME/state"
  assert_present "$decoy_state/caller-state-check.check-trust" \
    "caller-STATE unregister removed trust file from caller STATE"

  pass "happy path removes only the named check.sh and check-trust"
}

test_state_resolution_with_state_unset_under_override_and_home() {
  local home other_home override_state out err status override_sibling home_sibling
  home=$(make_home resolve-home)
  other_home=$(make_home resolve-other-home)
  override_state="$TMP_ROOT/resolve-override-state"
  mkdir -p "$override_state"
  out="$home/out.txt"
  err="$home/err.txt"

  override_sibling="$override_state/keep-override.check.sh"
  printf '#!/usr/bin/env bash\nprintf keep\n' > "$override_sibling"
  chmod 0700 "$override_sibling"
  write_registered_check_in_state "$override_state" override-check
  write_registered_check "$other_home" override-check

  status=0
  env -u STATE FM_HOME="$other_home" FM_STATE_OVERRIDE="$override_state" \
    "$UNREGISTER" override-check >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "unregister under FM_STATE_OVERRIDE with STATE unset"
  assert_contains "$(cat "$out")" "unregistered: state/override-check.check.sh" \
    "FM_STATE_OVERRIDE unregister did not report unregistration"
  assert_absent "$override_state/override-check.check.sh" \
    "FM_STATE_OVERRIDE unregister left check.sh behind"
  assert_absent "$override_state/override-check.check-trust" \
    "FM_STATE_OVERRIDE unregister left check-trust behind"
  assert_present "$override_sibling" \
    "FM_STATE_OVERRIDE unregister deleted a sibling check"
  assert_present "$other_home/state/override-check.check.sh" \
    "FM_STATE_OVERRIDE unregister touched FM_HOME/state check.sh"
  assert_present "$other_home/state/override-check.check-trust" \
    "FM_STATE_OVERRIDE unregister touched FM_HOME/state check-trust"

  write_registered_check_in_state "$override_state" override-only-check
  status=0
  env -u STATE -u FM_HOME FM_STATE_OVERRIDE="$override_state" \
    "$UNREGISTER" override-only-check >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "unregister under FM_STATE_OVERRIDE with STATE and FM_HOME unset"
  assert_contains "$(cat "$out")" "unregistered: state/override-only-check.check.sh" \
    "override-only unregister did not report unregistration"
  assert_absent "$override_state/override-only-check.check.sh" \
    "override-only unregister left check.sh behind"
  assert_absent "$override_state/override-only-check.check-trust" \
    "override-only unregister left check-trust behind"

  home_sibling="$home/state/keep-home.check.sh"
  printf '#!/usr/bin/env bash\nprintf keep\n' > "$home_sibling"
  chmod 0700 "$home_sibling"
  write_registered_check "$home" home-unset-check
  status=0
  env -u STATE -u FM_STATE_OVERRIDE FM_HOME="$home" \
    "$UNREGISTER" home-unset-check >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "unregister under FM_HOME with STATE and FM_STATE_OVERRIDE unset"
  assert_contains "$(cat "$out")" "unregistered: state/home-unset-check.check.sh" \
    "FM_HOME unset-override unregister did not report unregistration"
  assert_absent "$home/state/home-unset-check.check.sh" \
    "FM_HOME unset-override unregister left check.sh behind"
  assert_absent "$home/state/home-unset-check.check-trust" \
    "FM_HOME unset-override unregister left check-trust behind"
  assert_present "$home_sibling" \
    "FM_HOME unset-override unregister deleted a sibling check"

  write_registered_check "$home" cleared-override-check
  status=0
  env -u STATE FM_HOME="$home" FM_STATE_OVERRIDE='' \
    "$UNREGISTER" cleared-override-check >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "unregister under FM_HOME with STATE unset and empty FM_STATE_OVERRIDE"
  assert_contains "$(cat "$out")" "unregistered: state/cleared-override-check.check.sh" \
    "FM_HOME empty-override unregister did not report unregistration"
  assert_absent "$home/state/cleared-override-check.check.sh" \
    "FM_HOME empty-override unregister left check.sh behind"
  assert_absent "$home/state/cleared-override-check.check-trust" \
    "FM_HOME empty-override unregister left check-trust behind"
  assert_present "$home_sibling" \
    "FM_HOME empty-override unregister deleted a sibling check"

  pass "STATE-unset resolution honours FM_STATE_OVERRIDE and falls back to FM_HOME/state"
}

test_unsafe_hardlink_or_symlink_is_refused() {
  local home override_state out err status alias
  home=$(make_home unsafe)
  override_state="$TMP_ROOT/unsafe-override-state"
  mkdir -p "$override_state"
  out="$home/out.txt"
  err="$home/err.txt"
  write_registered_check "$home" custom
  alias="$home/custom-check.alias"
  ln "$home/state/custom.check.sh" "$alias"

  status=0
  FM_HOME="$home" "$UNREGISTER" custom >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "unregister hard-linked check.sh"
  assert_contains "$(cat "$err")" "unsafe to remove" "hard-link refusal used the wrong stderr"
  assert_present "$home/state/custom.check.sh" "hard-link refusal deleted check.sh"
  assert_present "$home/state/custom.check-trust" "hard-link refusal deleted check-trust"
  assert_present "$alias" "hard-link refusal deleted the external alias"

  rm -f "$alias"
  rm -f "$home/state/custom.check.sh"
  printf '#!/usr/bin/env bash\nprintf target\n' > "$home/outside.check.sh"
  chmod 0700 "$home/outside.check.sh"
  ln -s "$home/outside.check.sh" "$home/state/custom.check.sh"

  status=0
  FM_HOME="$home" "$UNREGISTER" custom >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "unregister symlink check.sh"
  assert_contains "$(cat "$err")" "unsafe to remove" "symlink refusal used the wrong stderr"
  assert_present "$home/state/custom.check.sh" "symlink refusal removed the state symlink"
  assert_present "$home/outside.check.sh" "symlink refusal deleted the external target"
  assert_present "$home/state/custom.check-trust" "symlink refusal deleted check-trust"

  write_registered_check_in_state "$override_state" override-unsafe
  ln "$override_state/override-unsafe.check.sh" "$alias"
  status=0
  env -u STATE FM_STATE_OVERRIDE="$override_state" \
    "$UNREGISTER" override-unsafe >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "unregister hard-linked check.sh under FM_STATE_OVERRIDE"
  assert_contains "$(cat "$err")" "unsafe to remove" \
    "override hard-link refusal used the wrong stderr"
  assert_present "$override_state/override-unsafe.check.sh" \
    "override hard-link refusal deleted check.sh"
  assert_present "$override_state/override-unsafe.check-trust" \
    "override hard-link refusal deleted check-trust"
  assert_present "$alias" "override hard-link refusal deleted the external alias"

  rm -f "$alias"
  rm -f "$override_state/override-unsafe.check.sh"
  ln -s "$home/outside.check.sh" "$override_state/override-unsafe.check.sh"
  status=0
  env -u STATE FM_STATE_OVERRIDE="$override_state" \
    "$UNREGISTER" override-unsafe >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "unregister symlink check.sh under FM_STATE_OVERRIDE"
  assert_contains "$(cat "$err")" "unsafe to remove" \
    "override symlink refusal used the wrong stderr"
  assert_present "$override_state/override-unsafe.check.sh" \
    "override symlink refusal removed the state symlink"
  assert_present "$home/outside.check.sh" \
    "override symlink refusal deleted the external target"
  assert_present "$override_state/override-unsafe.check-trust" \
    "override symlink refusal deleted check-trust"

  pass "hard-linked or symlinked artifacts are refused and left in place"
}

test_empty_id_and_empty_state_refuse_without_stray_rm
test_happy_path_removes_only_check_and_trust
test_state_resolution_with_state_unset_under_override_and_home
test_unsafe_hardlink_or_symlink_is_refused

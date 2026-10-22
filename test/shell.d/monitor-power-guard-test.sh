#!/bin/bash

set -uo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command jq

test_tmp=$(mktemp -d)
fake_bin=$test_tmp/bin
home=$test_tmp/home
run=$test_tmp/run
drm=$test_tmp/drm
monitors=$test_tmp/monitors.json
actions=$test_tmp/actions
ddc_sequence=$test_tmp/ddc-sequence
ddc_counter=$test_tmp/ddc-counter
state=$test_tmp/state
guard_log=$test_tmp/guard.log

cleanup() {
  rm -rf "$test_tmp"
}
trap cleanup EXIT

mkdir -p "$fake_bin" "$home" "$run" "$drm/card1-HDMI-A-1" "$state"

cat >"$fake_bin/hyprctl" <<'SH'
#!/bin/bash

set -u

case ${1:-} in
monitors)
  cat "$FAKE_MONITORS"
  ;;
eval)
  lua=${2:-}
  printf 'eval %s\n' "$lua" >>"$FAKE_ACTIONS"
  output=$(sed -n 's/.*output = "\([^"]*\)".*/\1/p' <<<"$lua")
  [[ -n $output ]] || exit 0
  disabled=$(sed -n 's/.*disabled = \([a-z]*\).*/\1/p' <<<"$lua")
  position=$(sed -n 's/.*position = "\([^"]*\)".*/\1/p' <<<"$lua")
  scale=$(sed -n 's/.*scale = \([0-9.]*\).*/\1/p' <<<"$lua")
  temporary=$(mktemp "$FAKE_MONITORS.tmp.XXXXXX")
  if jq --arg output "$output" --arg disabled "$disabled" --arg position "$position" --arg scale "$scale" '
    map(if .name == $output then
      .disabled = (if $disabled == "" then .disabled else ($disabled == "true") end)
      | if $disabled == "false" then .width = 1920 | .height = 1080 | .dpmsStatus = true else . end
      | if $position != "" and $position != "auto" then
          .x = ($position | split("x")[0] | tonumber)
          | .y = ($position | split("x")[1] | tonumber)
        else . end
      | if $scale != "" then .scale = ($scale | tonumber) else . end
    else . end)' "$FAKE_MONITORS" >"$temporary"; then
    mv -f "$temporary" "$FAKE_MONITORS"
  else
    rm -f "$temporary"
  fi
  ;;
reload)
  printf 'reload\n' >>"$FAKE_ACTIONS"
  ;;
*)
  exit 1
  ;;
esac
SH

cat >"$fake_bin/ddcutil" <<'SH'
#!/bin/bash

set -u

if [[ $* == *"getvcp D6"* ]]; then
  count=0
  [[ -f $FAKE_DDC_COUNTER ]] && read -r count <"$FAKE_DDC_COUNTER"
  count=$((count + 1))
  printf '%s\n' "$count" >"$FAKE_DDC_COUNTER"

  line=$(sed -n "${count}p" "$FAKE_DDC_SEQUENCE")
  if [[ -z $line ]]; then
    line=$(awk 'NF { last = $0 } END { print last }' "$FAKE_DDC_SEQUENCE")
  fi
  [[ -n $line ]] || line='VCP D6 SNC x01'

  if [[ $line == ERR:* ]]; then
    printf '%s\n' "${line#ERR:}" >&2
    exit 1
  fi
  printf '%s\n' "$line"
  exit 0
fi

if [[ $* == *"setvcp D6 01"* ]]; then
  printf 'ddc-power-on\n' >>"$FAKE_ACTIONS"
  exit 0
fi

exit 1
SH

cat >"$fake_bin/omarchy-notification-send" <<'SH'
#!/bin/bash
printf 'notify %s\n' "$*" >>"$FAKE_ACTIONS"
SH

cat >"$fake_bin/omarchy-i18n" <<'SH'
#!/bin/bash
key=${1:-}
shift || true
printf '%s' "$key"
(( $# )) && printf ' %s' "$@"
printf '\n'
SH

cat >"$fake_bin/systemctl" <<'SH'
#!/bin/bash
printf 'systemctl %s\n' "$*" >>"$FAKE_ACTIONS"
if [[ ${FAKE_SYSTEMCTL_FAIL:-} == "${2:-}" ]]; then
  exit 1
fi
SH

cat >"$fake_bin/omarchy-hw-clamshell" <<'SH'
#!/bin/bash
exit 1
SH

cat >"$fake_bin/omarchy-hyprland-monitor-internal" <<'SH'
#!/bin/bash
[[ ${1:-} == "on" ]] || exit 1
"$(dirname "$0")/hyprctl" eval 'hl.monitor({ output = "eDP-1", disabled = false })'
rm -f "$HOME/.local/state/omarchy/toggles/hypr/internal-monitor-disable.lua"
SH

chmod +x "$fake_bin"/*

set_monitors() {
  printf '%s\n' "$1" >"$monitors"
}

default_monitors() {
  cat >"$monitors" <<'JSON'
[
  {"name":"eDP-1","mirrorOf":"none","disabled":false,"width":2560,"height":1600,"refreshRate":120,"x":0,"y":0,"scale":2,"transform":0,"vrr":false,"dpmsStatus":true,"availableModes":["2560x1600@120.00Hz"]},
  {"name":"HDMI-A-1","mirrorOf":"none","disabled":false,"width":1920,"height":1080,"refreshRate":144,"x":1280,"y":0,"scale":1.25,"transform":0,"vrr":false,"dpmsStatus":true,"availableModes":["1920x1080@144.00Hz","1920x1080@60.00Hz"]}
]
JSON
}

set_output() {
  local output=$1 disabled=$2 temporary
  temporary=$(mktemp "$monitors.tmp.XXXXXX")
  jq --arg output "$output" --argjson disabled "$disabled" '
    map(if .name == $output then
      .disabled = $disabled
      | if $disabled then .width = 0 | .height = 0 else .width = 1920 | .height = 1080 | .dpmsStatus = true end
    else . end)' "$monitors" >"$temporary"
  mv -f "$temporary" "$monitors"
}

reset_state() {
  rm -rf "$state" "$home/.local/state/omarchy/toggles" "$run"
  mkdir -p "$state" "$home/.local/state/omarchy/toggles/hypr" "$run" "$drm/card1-HDMI-A-1"
  : >"$actions"
  : >"$ddc_counter"
  printf 'VCP D6 SNC x01\n' >"$ddc_sequence"
  printf 'connected\n' >"$drm/card1-HDMI-A-1/status"
  : >"$drm/i2c-5"
  ln -sfn "$drm/i2c-5" "$drm/card1-HDMI-A-1/ddc"
  printf 'edid-default\n' >"$drm/card1-HDMI-A-1/edid"
  default_monitors
}

run_guard() {
  HOME="$home" \
    XDG_STATE_HOME="$home/.local/state" \
    XDG_RUNTIME_DIR="$run" \
    OMARCHY_DRM_PATH="$drm" \
    MONITOR_POWER_GUARD_STATE_DIR="$state" \
    MONITOR_POWER_GUARD_STARTUP_GRACE="${MONITOR_POWER_GUARD_STARTUP_GRACE:-0}" \
    MONITOR_POWER_GUARD_RESTORE_GRACE="${MONITOR_POWER_GUARD_RESTORE_GRACE:-0}" \
    MONITOR_POWER_GUARD_RESUME_GRACE="${MONITOR_POWER_GUARD_RESUME_GRACE:-0}" \
    MONITOR_POWER_GUARD_CONFIRM_DELAY="${MONITOR_POWER_GUARD_CONFIRM_DELAY:-0}" \
    MONITOR_POWER_GUARD_WAKE_RETRY="${MONITOR_POWER_GUARD_WAKE_RETRY:-0}" \
    MONITOR_POWER_GUARD_WAKE_COOLDOWN="${MONITOR_POWER_GUARD_WAKE_COOLDOWN:-0}" \
    MONITOR_POWER_GUARD_CONFIRM_SAMPLES="${MONITOR_POWER_GUARD_CONFIRM_SAMPLES:-4}" \
    MONITOR_POWER_GUARD_ERROR_CONFIRM_SAMPLES="${MONITOR_POWER_GUARD_ERROR_CONFIRM_SAMPLES:-8}" \
    MONITOR_POWER_GUARD_ERROR_CONFIRM_DELAY="${MONITOR_POWER_GUARD_ERROR_CONFIRM_DELAY:-0.5}" \
    PATH="$fake_bin:$ROOT/bin:$PATH" \
    FAKE_MONITORS="$monitors" \
    FAKE_ACTIONS="$actions" \
    FAKE_DDC_SEQUENCE="$ddc_sequence" \
    FAKE_DDC_COUNTER="$ddc_counter" \
    "$ROOT/bin/omarchy-hyprland-monitor-power-guard" "$@"
}

run_guard_defaults() {
  HOME="$home" \
    XDG_STATE_HOME="$home/.local/state" \
    XDG_RUNTIME_DIR="$run" \
    OMARCHY_DRM_PATH="$drm" \
    MONITOR_POWER_GUARD_STATE_DIR="$state" \
    PATH="$fake_bin:$ROOT/bin:$PATH" \
    FAKE_MONITORS="$monitors" \
    FAKE_ACTIONS="$actions" \
    FAKE_DDC_SEQUENCE="$ddc_sequence" \
    FAKE_DDC_COUNTER="$ddc_counter" \
    "$ROOT/bin/omarchy-hyprland-monitor-power-guard" "$@"
}

run_toggle() {
  HOME="$home" \
    XDG_STATE_HOME="$home/.local/state" \
    XDG_RUNTIME_DIR="$run" \
    OMARCHY_PATH="$ROOT" \
    OMARCHY_DRM_PATH="$drm" \
    MONITOR_POWER_GUARD_STATE_DIR="$state" \
    PATH="$fake_bin:$ROOT/bin:$PATH" \
    FAKE_MONITORS="$monitors" \
    FAKE_ACTIONS="$actions" \
    FAKE_DDC_SEQUENCE="$ddc_sequence" \
    FAKE_DDC_COUNTER="$ddc_counter" \
    "$ROOT/bin/omarchy-toggle-monitor-power-guard" "$@"
}

assert_enabled() {
  local output=$1
  jq -e --arg output "$output" '.[] | select(.name == $output)
    | .disabled != true and .width > 0 and .height > 0 and .dpmsStatus == true' "$monitors" >/dev/null ||
    fail "$output is enabled and live"
}

assert_disabled() {
  local output=$1
  jq -e --arg output "$output" '.[] | select(.name == $output) | .disabled == true' "$monitors" >/dev/null ||
    fail "$output is disabled"
}

assert_state_exists() {
  [[ -s $state/suspended/HDMI-A-1.json ]] || fail "guard saved the suspended state"
}

assert_state_absent() {
  [[ ! -e $state/suspended/HDMI-A-1.json ]] || fail "guard cleared the suspended state"
}

assert_action_contains() {
  local expected=$1
  grep -F "$expected" "$actions" >/dev/null || fail "action log contains: $expected"
}

reset_state

# The toggle command owns the flag and the service state. Keep both in sync so
# an enable that cannot start the service does not leave the flag behind.
run_toggle on >/dev/null 2>&1 ||
  fail "monitor power guard toggles on"
[[ -f $home/.local/state/omarchy/toggles/monitor-power-guard ]] ||
  fail "toggle writes the opt-in flag"
[[ -f $home/.config/systemd/user/omarchy-hyprland-monitor-power-guard.service ]] ||
  fail "toggle installs the user service before enabling it"
assert_action_contains "systemctl --user enable --now omarchy-hyprland-monitor-power-guard.service"

run_toggle off >/dev/null 2>&1 ||
  fail "monitor power guard toggles off"
[[ ! -e $home/.local/state/omarchy/toggles/monitor-power-guard ]] ||
  fail "toggle removes the opt-in flag"
assert_action_contains "systemctl --user stop omarchy-hyprland-monitor-power-guard.service"
assert_action_contains "systemctl --user disable omarchy-hyprland-monitor-power-guard.service"
pass "monitor power guard toggles its service and flag together"

reset_state
printf 'VCP D6 SNC x04\nVCP D6 SNC x04\nVCP D6 SNC x04\nVCP D6 SNC x04\n' >"$ddc_sequence"
run_guard --once >"$guard_log" 2>&1
assert_disabled HDMI-A-1
assert_state_exists
assert_action_contains 'eval hl.monitor({ output = "HDMI-A-1", disabled = true })'
grep -F 'monitor.powerGuardTurnedOff' "$actions" >/dev/null ||
  fail "guard notifies when a monitor turns off"
pass "a confirmed off monitor is disabled and its layout is saved"

reset_state
printf 'VCP D6 SNC x04\nERR:Device or resource busy\n' >"$ddc_sequence"
run_guard --once >"$guard_log" 2>&1
assert_enabled HDMI-A-1
assert_state_absent
pass "a transient confirmation error does not disable the monitor"

reset_state
printf 'VCP D6 SNC x04\nVCP D6 SNC x01\n' >"$ddc_sequence"
run_guard --once >"$guard_log" 2>&1
assert_enabled HDMI-A-1
assert_state_absent
pass "a monitor that answers the confirmation probe stays enabled"

reset_state
printf 'ERR:DDC communication failed\nERR:DDC communication failed\n' >"$ddc_sequence"
run_guard --once >"$guard_log" 2>&1
assert_enabled HDMI-A-1
assert_action_contains 'monitor.powerGuardUnsupported'
pass "a monitor whose DDC has never worked fails open"

reset_state
printf 'VCP D6 SNC x04\nVCP D6 SNC x04\nVCP D6 SNC x04\nVCP D6 SNC x04\n' >"$ddc_sequence"
run_guard --once >"$guard_log" 2>&1
assert_disabled HDMI-A-1
jq -e '.config.mode == "1920x1080@144" and .config.position == "1280x0" and .config.scale == 1.25' \
  "$state/suspended/HDMI-A-1.json" >/dev/null ||
  fail "guard saves the full monitor layout"
set_output HDMI-A-1 true
printf 'VCP D6 SNC x01\nVCP D6 SNC x01\n' >"$ddc_sequence"
run_guard --once >"$guard_log" 2>&1
assert_enabled HDMI-A-1
assert_state_absent
assert_action_contains 'mode = "1920x1080@144"'
jq -e '.[] | select(.name == "HDMI-A-1") | .x == 1280 and .y == 0 and .scale == 1.25 and .dpmsStatus == true' \
  "$monitors" >/dev/null || fail "guard restores position, scale, and DPMS"
pass "a returning monitor is restored with its saved mode and position"

# An unreadable EDID during an outage is not proof that the monitor was
# replaced. The saved layout must survive until a readable identity differs.
reset_state
printf 'VCP D6 SNC x04\nVCP D6 SNC x04\nVCP D6 SNC x04\nVCP D6 SNC x04\n' >"$ddc_sequence"
run_guard --once >"$guard_log" 2>&1
assert_disabled HDMI-A-1
rm -f "$drm/card1-HDMI-A-1/edid"
set_output HDMI-A-1 true
printf 'VCP D6 SNC x01\nVCP D6 SNC x01\n' >"$ddc_sequence"
run_guard --once >"$guard_log" 2>&1
assert_enabled HDMI-A-1
assert_state_absent
assert_action_contains 'mode = "1920x1080@144"'
pass "an unreadable EDID keeps the saved monitor layout"

# Dry-run must not clear or rewrite saved state when a replacement monitor is
# attached, even though the normal recovery path would discard the old layout.
reset_state
printf 'VCP D6 SNC x04\nVCP D6 SNC x04\nVCP D6 SNC x04\nVCP D6 SNC x04\n' >"$ddc_sequence"
run_guard --once >"$guard_log" 2>&1
assert_state_exists
printf 'replacement-edid\n' >"$drm/card1-HDMI-A-1/edid"
set_output HDMI-A-1 true
printf 'VCP D6 SNC x01\nVCP D6 SNC x01\n' >"$ddc_sequence"
: >"$actions"
run_guard --once --dry-run >"$guard_log" 2>&1
assert_state_exists
[[ ! -s $actions ]] || fail "dry-run leaves a replacement monitor's state untouched"
pass "dry-run does not discard saved state for a replacement monitor"

reset_state
jq 'map(if .name == "eDP-1" then .disabled = true | .width = 0 | .height = 0 else . end)' "$monitors" >"$monitors.tmp" &&
  mv -f "$monitors.tmp" "$monitors"
printf 'hl.monitor({ output = "eDP-1", disabled = true })\n' >"$home/.local/state/omarchy/toggles/hypr/internal-monitor-disable.lua"
printf 'VCP D6 SNC x04\nVCP D6 SNC x04\nVCP D6 SNC x04\nVCP D6 SNC x04\n' >"$ddc_sequence"
run_guard --once >"$guard_log" 2>&1
assert_disabled HDMI-A-1
assert_enabled eDP-1
[[ -f $home/.local/state/omarchy/toggles/hypr/internal-monitor-disable.lua ]] ||
  fail "external-only mode survives the outage"
[[ ! -s $home/.local/state/omarchy/toggles/hypr/internal-monitor-disable.lua ]] ||
  fail "external-only flag is parked while the internal panel is needed"
[[ -s $state/external-only.flag ]] || fail "external-only rule is kept in guard state"
jq -e '.external_only == true and .saw_unreachable == true' "$state/suspended/HDMI-A-1.json" >/dev/null ||
  fail "guard records external-only mode and boolean state"

set_output HDMI-A-1 true
printf 'VCP D6 SNC x01\nVCP D6 SNC x01\n' >"$ddc_sequence"
run_guard --once >"$guard_log" 2>&1
assert_enabled HDMI-A-1
assert_disabled eDP-1
assert_state_absent
grep -F 'hl.monitor({ output = "eDP-1", disabled = true })' \
  "$home/.local/state/omarchy/toggles/hypr/internal-monitor-disable.lua" >/dev/null ||
  fail "external-only mode is preserved after restore"
[[ ! -e $state/external-only.flag ]] || fail "parked external-only rule is cleared after restore"
pass "external-only mode is preserved across an outage and restore"

# Turning the guard off while the external monitor is dark must never leave the
# laptop panel hidden. A live Hyprland output is not proof that the monitor is
# showing anything; require a DDC answer before restoring external-only mode.
reset_state
mkdir -p "$home/.local/state/omarchy/toggles/hypr"
printf 'hl.monitor({ output = "eDP-1", disabled = true })\n' \
  >"$home/.local/state/omarchy/toggles/hypr/internal-monitor-disable.lua"
printf 'VCP D6 SNC x04\nVCP D6 SNC x04\nVCP D6 SNC x04\n' >"$ddc_sequence"
run_guard --once >"$guard_log" 2>&1
assert_disabled HDMI-A-1
set_output HDMI-A-1 false
printf 'ERR:DDC communication failed\n' >"$ddc_sequence"
run_toggle off >"$guard_log" 2>&1 || fail "toggle off returns successfully when the internal panel is the fallback"
assert_enabled HDMI-A-1
assert_enabled eDP-1
assert_state_absent
[[ ! -s $home/.local/state/omarchy/toggles/hypr/internal-monitor-disable.lua ]] ||
  fail "toggle off leaves external-only mode parked when the monitor is dark"
pass "turning off with a dark external monitor keeps the internal panel visible"

reset_state
printf 'VCP D6 SNC x04\nVCP D6 SNC x04\nVCP D6 SNC x04\n' >"$ddc_sequence"
run_guard --once --dry-run >"$guard_log" 2>&1
assert_enabled HDMI-A-1
assert_state_absent
[[ ! -s $actions ]] || fail "dry-run leaves Hyprland and DDC untouched"
pass "dry-run does not change Hyprland, DDC, or guard state"

reset_state
jq 'map(select(.name != "eDP-1"))' "$monitors" >"$monitors.tmp" &&
  mv -f "$monitors.tmp" "$monitors"
printf 'VCP D6 SNC x04\nVCP D6 SNC x04\nVCP D6 SNC x04\n' >"$ddc_sequence"
run_guard --once >"$guard_log" 2>&1
assert_enabled HDMI-A-1
assert_state_absent
grep -F 'refusing to disable HDMI-A-1' "$guard_log" >/dev/null ||
  fail "guard refuses to disable the only display"
pass "the last active output is never disabled"

# A fresh --once run must probe immediately. The old DPMS resume guard treated
# the first sample as a wake-up and skipped detection entirely.
reset_state
printf 'VCP D6 SNC x04\n' >"$ddc_sequence"
run_guard_defaults --once >"$guard_log" 2>&1 ||
  fail "default --once exits cleanly"
assert_disabled HDMI-A-1
assert_state_exists
[[ $(cat "$ddc_counter" 2>/dev/null || echo 0) -ge 1 ]] ||
  fail "default --once performs a DDC read"
pass "default --once probes immediately"

# A monitor that worked before can stop answering when it loses power. This is
# the only case where an unreachable DDC bus is treated as an outage, and it
# requires a persisted DDC success marker plus repeated probes.
reset_state
printf 'edid-known-good\n' >"$drm/card1-HDMI-A-1/edid"
printf 'VCP D6 SNC x01\n' >"$ddc_sequence"
run_guard --once >"$guard_log" 2>&1
[[ -f $state/ddc-ok/HDMI-A-1 ]] || fail "guard records a successful DDC probe"
printf 'ERR:DDC communication failed\n' >"$ddc_sequence"
MONITOR_POWER_GUARD_CONFIRM_SAMPLES=1 MONITOR_POWER_GUARD_ERROR_CONFIRM_SAMPLES=1 MONITOR_POWER_GUARD_ERROR_CONFIRM_DELAY=0 run_guard --once >"$guard_log" 2>&1
assert_disabled HDMI-A-1
assert_state_exists
pass "a known-good monitor that stops answering is treated as a power loss"

# A different monitor on the same connector must not inherit the old monitor's
# DDC success marker; otherwise a monitor without DDC could be treated as a
# power loss and disabled.
reset_state
printf 'edid-a\n' >"$drm/card1-HDMI-A-1/edid"
printf 'VCP D6 SNC x01\n' >"$ddc_sequence"
run_guard --once >"$guard_log" 2>&1
[[ -f $state/ddc-ok/HDMI-A-1 ]] || fail "guard persists a DDC marker for the monitor"
printf 'edid-b\n' >"$drm/card1-HDMI-A-1/edid"
printf 'ERR:DDC communication failed\n' >"$ddc_sequence"
MONITOR_POWER_GUARD_CONFIRM_SAMPLES=1 MONITOR_POWER_GUARD_ERROR_CONFIRM_SAMPLES=1 MONITOR_POWER_GUARD_ERROR_CONFIRM_DELAY=0 \
  run_guard --once >"$guard_log" 2>&1
assert_enabled HDMI-A-1
assert_state_absent
[[ ! -f $state/ddc-ok/HDMI-A-1 ]] || fail "guard forgets a DDC marker after a monitor swap"
pass "a replaced monitor does not inherit the old DDC success marker"
rm -f "$drm/card1-HDMI-A-1/edid"

# The same check must run while the service is already looping, not only at
# startup. Otherwise a monitor swap on a known-good connector could still be
# mistaken for a power loss.
reset_state
mkdir -p "$state/ddc-ok"
printf 'edid-a\n' >"$state/ddc-ok/HDMI-A-1"
printf 'edid-b\n' >"$drm/card1-HDMI-A-1/edid"
printf 'ERR:DDC communication failed\n' >"$ddc_sequence"
(
  export HOME="$home" XDG_STATE_HOME="$home/.local/state" XDG_RUNTIME_DIR="$run"
  export OMARCHY_DRM_PATH="$drm" MONITOR_POWER_GUARD_STATE_DIR="$state"
  export MONITOR_POWER_GUARD_STARTUP_GRACE=0 MONITOR_POWER_GUARD_ERROR_CONFIRM_SAMPLES=1 MONITOR_POWER_GUARD_ERROR_CONFIRM_DELAY=0
  export PATH="$fake_bin:$ROOT/bin:$PATH" FAKE_MONITORS="$monitors" FAKE_ACTIONS="$actions"
  export FAKE_DDC_SEQUENCE="$ddc_sequence" FAKE_DDC_COUNTER="$ddc_counter"
  source "$ROOT/bin/omarchy-hyprland-monitor-power-guard"
  load_monitors
  DDC_OK_ONCE[HDMI-A-1]=1
  check_active_output HDMI-A-1
) >"$guard_log" 2>&1
assert_enabled HDMI-A-1
assert_state_absent
[[ ! -f $state/ddc-ok/HDMI-A-1 ]] || fail "live monitor swap invalidates the DDC marker"
pass "a monitor swap while the guard is running is detected"
rm -f "$drm/card1-HDMI-A-1/edid"

# A saved layout belongs to the monitor that produced it. If the EDID changes
# while the output is suspended, do not restore the old resolution/position on
# the replacement monitor.
reset_state
printf 'edid-original\n' >"$drm/card1-HDMI-A-1/edid"
printf 'VCP D6 SNC x04\nVCP D6 SNC x04\nVCP D6 SNC x04\n' >"$ddc_sequence"
run_guard --once >"$guard_log" 2>&1
assert_disabled HDMI-A-1
set_output HDMI-A-1 false
printf 'edid-replacement\n' >"$drm/card1-HDMI-A-1/edid"
printf 'VCP D6 SNC x01\n' >"$ddc_sequence"
: >"$actions"
run_guard --once >"$guard_log" 2>&1
assert_enabled HDMI-A-1
assert_state_absent
grep -F 'mode = "preferred"' "$actions" >/dev/null ||
  fail "replacement monitor gets a preferred mode instead of the old layout"
pass "a replacement monitor does not get the old saved layout"
rm -f "$drm/card1-HDMI-A-1/edid"

# If the process dies after parking the external-only rule but before a saved
# state exists, the next run must put the rule back rather than leave the user
# in a permanent dual-screen layout.
reset_state
mkdir -p "$home/.local/state/omarchy/toggles/hypr"
printf 'hl.monitor({ output = "eDP-1", disabled = true })\n' \
  >"$home/.local/state/omarchy/toggles/hypr/internal-monitor-disable.lua"
printf 'VCP D6 SNC x04\nVCP D6 SNC x04\nVCP D6 SNC x04\n' >"$ddc_sequence"
run_guard --once >"$guard_log" 2>&1
assert_disabled HDMI-A-1
[[ -s $state/external-only.flag ]] || fail "outage parks the external-only rule"
set_output HDMI-A-1 false
rm -f "$state/suspended/HDMI-A-1.json"
printf 'VCP D6 SNC x01\n' >"$ddc_sequence"
run_guard --once >"$guard_log" 2>&1
assert_enabled HDMI-A-1
assert_disabled eDP-1
[[ -s $home/.local/state/omarchy/toggles/hypr/internal-monitor-disable.lua ]] ||
  fail "parked external-only rule is restored after a crash"
[[ ! -e $state/external-only.flag ]] || fail "restored parked rule is cleared"
pass "a parked external-only rule survives a crash"

# A cold-start error gets a quiet grace window instead of an immediate
# "unsupported display" notification.
reset_state
printf 'ERR:DDC communication failed\n' >"$ddc_sequence"
MONITOR_POWER_GUARD_STARTUP_GRACE=100 run_guard --once --debug >"$guard_log" 2>&1
assert_enabled HDMI-A-1
assert_state_absent
grep -F 'startup grace' "$guard_log" >/dev/null ||
  fail "guard logs the startup grace: $(cat "$guard_log")"
if grep -F 'monitor.powerGuardUnsupported' "$actions" >/dev/null; then
  fail "guard stays quiet during the startup grace"
fi
pass "startup grace defers unsupported-display decisions"

# A short suspend can be missed by the DPMS transition. A long gap between
# checks is also treated as a resume, suppressing an error-window false positive.
reset_state
printf 'ERR:DDC communication failed\n' >"$ddc_sequence"
(
  export HOME="$home" XDG_STATE_HOME="$home/.local/state" XDG_RUNTIME_DIR="$run"
  export OMARCHY_DRM_PATH="$drm" MONITOR_POWER_GUARD_STATE_DIR="$state"
  export MONITOR_POWER_GUARD_STARTUP_GRACE=0 MONITOR_POWER_GUARD_ERROR_CONFIRM_SAMPLES=1 MONITOR_POWER_GUARD_ERROR_CONFIRM_DELAY=0
  export PATH="$fake_bin:$ROOT/bin:$PATH" FAKE_MONITORS="$monitors" FAKE_ACTIONS="$actions"
  export FAKE_DDC_SEQUENCE="$ddc_sequence" FAKE_DDC_COUNTER="$ddc_counter"
  source "$ROOT/bin/omarchy-hyprland-monitor-power-guard"
  DEBUG=1
  load_monitors
  LAST_CHECK_EPOCH=$((EPOCHSECONDS - 10))
  check_once
) >"$guard_log" 2>&1
assert_enabled HDMI-A-1
assert_state_absent
grep -F 'long gap between checks' "$guard_log" >/dev/null ||
  fail "guard detects a resume from a long check gap"
pass "a resume suppresses the error-window false positive"

# Lock contention must not crash with an unset MODE variable.
reset_state
(
  exec 9>"$run/omarchy-monitor-power-guard.lock"
  flock 9
  sleep 1
) &
lock_holder=$!
sleep 0.1
MONITOR_POWER_GUARD_CONFIRM_SAMPLES=1 run_guard --once >"$guard_log" 2>&1
lock_rc=$?
kill "$lock_holder" 2>/dev/null || true
wait "$lock_holder" 2>/dev/null || true
[[ $lock_rc == 0 ]] || fail "lock contention in --once exits cleanly"
grep -F 'another instance is already running' "$guard_log" >/dev/null ||
  fail "lock contention is reported"
pass "lock contention does not crash"

# The service waits briefly for the previous process to exit. If the lock is
# still held after that, it exits 75 so systemd can restart it (the unit no
# longer suppresses restarts for this status).
reset_state
(
  exec 9>"$run/omarchy-monitor-power-guard.lock"
  flock 9
  sleep 2
) &
lock_holder=$!
sleep 0.2
MONITOR_POWER_GUARD_LOCK_WAIT=1 run_guard >"$guard_log" 2>&1
run_rc=$?
kill "$lock_holder" 2>/dev/null || true
wait "$lock_holder" 2>/dev/null || true
[[ $run_rc == 75 ]] || fail "run mode exits 75 when the lock stays busy"
grep -F 'another instance is still running' "$guard_log" >/dev/null ||
  fail "run-mode lock contention is reported"
pass "run mode waits for a transient lock and asks systemd to retry"

# A second external output that is enabled but DPMS-off is not a usable
# fallback. With no internal panel, the guard must refuse to darken the room.
reset_state
jq 'map(select(.name != "eDP-1")) + [{"name":"DP-1","mirrorOf":"none","disabled":false,"width":1920,"height":1080,"refreshRate":60,"x":0,"y":0,"scale":1,"transform":0,"vrr":false,"dpmsStatus":false,"availableModes":["1920x1080@60.00Hz"]}]' \
  "$monitors" >"$monitors.tmp" && mv -f "$monitors.tmp" "$monitors"
printf 'VCP D6 SNC x04\nVCP D6 SNC x04\nVCP D6 SNC x04\n' >"$ddc_sequence"
run_guard --once >"$guard_log" 2>&1
assert_enabled HDMI-A-1
assert_state_absent
grep -F 'no other active display is available' "$guard_log" >/dev/null ||
  fail "guard refuses to disable the only lit output"
pass "a DPMS-off output is not treated as a visible fallback"

# Restore must not clear the state when the output comes back but DDC still
# says the monitor is dark. Otherwise the next poll can flap the output.
reset_state
printf 'VCP D6 SNC x04\nVCP D6 SNC x04\nVCP D6 SNC x04\nVCP D6 SNC x04\n' >"$ddc_sequence"
run_guard --once >"$guard_log" 2>&1
set_output HDMI-A-1 true
printf 'VCP D6 SNC x01\nVCP D6 SNC x04\n' >"$ddc_sequence"
run_guard --once >"$guard_log" 2>&1
assert_disabled HDMI-A-1
assert_state_exists
if grep -F 'monitor.powerGuardRestored' "$actions" >/dev/null; then
  fail "guard does not report a restore it has not verified"
fi
pass "an unverified restore keeps the suspended state"

# A failed restore must keep its saved state, even when another display is
# live. Otherwise turning the feature off would discard the only way back.
reset_state
printf 'VCP D6 SNC x04\nVCP D6 SNC x04\nVCP D6 SNC x04\nVCP D6 SNC x04\n' >"$ddc_sequence"
run_guard --once >"$guard_log" 2>&1
assert_state_exists
mv "$fake_bin/hyprctl" "$fake_bin/hyprctl.real"
cat >"$fake_bin/hyprctl" <<'INNER'
#!/bin/bash
[[ ${1:-} == "eval" ]] && exit 1
exec "$(dirname "$0")/hyprctl.real" "$@"
INNER
chmod +x "$fake_bin/hyprctl"
run_guard --restore-all >"$guard_log" 2>&1
restore_rc=$?
mv -f "$fake_bin/hyprctl.real" "$fake_bin/hyprctl"
[[ $restore_rc != 0 ]] || fail "restore-all reports a failed output"
assert_state_exists
pass "a failed restore keeps the saved state"

# Turning the feature off must not strand a display the guard disabled.
reset_state
run_toggle on >/dev/null 2>&1 || fail "monitor power guard toggles on before restore test"
printf 'VCP D6 SNC x04\nVCP D6 SNC x04\nVCP D6 SNC x04\nVCP D6 SNC x04\n' >"$ddc_sequence"
run_guard --once >"$guard_log" 2>&1
assert_disabled HDMI-A-1
assert_state_exists
run_toggle off >/dev/null 2>&1 || fail "monitor power guard toggles off after an outage"
assert_enabled HDMI-A-1
assert_state_absent
pass "turning the guard off restores a stranded output"

# Failed enable must roll the opt-in flag back.
reset_state
FAKE_SYSTEMCTL_FAIL=enable run_toggle on >/dev/null 2>&1
[[ $? != 0 ]] || fail "toggle on fails when the service cannot start"
[[ ! -e $home/.local/state/omarchy/toggles/monitor-power-guard ]] ||
  fail "failed enable rolls the flag back"
assert_action_contains 'monitor.powerGuardFailed'
pass "failed enable rolls back the opt-in flag"

# Failed stop must leave the flag in place so the user can retry.
reset_state
run_toggle on >/dev/null 2>&1 || fail "monitor power guard toggles on before stop-failure test"
FAKE_SYSTEMCTL_FAIL=stop run_toggle off >/dev/null 2>&1
[[ $? != 0 ]] || fail "toggle off fails when the service cannot stop"
[[ -f $home/.local/state/omarchy/toggles/monitor-power-guard ]] ||
  fail "failed stop keeps the opt-in flag"
pass "failed stop keeps the opt-in flag"

# If every output ends up disabled (a reload race or a manual toggle), the
# guard must bring the internal panel back instead of waiting forever.
reset_state
printf 'VCP D6 SNC x04\nVCP D6 SNC x04\nVCP D6 SNC x04\nVCP D6 SNC x04\n' >"$ddc_sequence"
run_guard --once >"$guard_log" 2>&1
jq 'map(.disabled = true | .width = 0 | .height = 0)' "$monitors" >"$monitors.tmp" && mv -f "$monitors.tmp" "$monitors"
printf 'VCP D6 SNC x04\nVCP D6 SNC x04\nVCP D6 SNC x04\nVCP D6 SNC x04\n' >"$ddc_sequence"
run_guard --once --dry-run >"$guard_log" 2>&1
assert_disabled eDP-1
assert_state_exists
run_guard --once >"$guard_log" 2>&1
assert_enabled eDP-1
grep -F 'all displays are disabled' "$guard_log" >/dev/null ||
  fail "guard recovers a session with every output disabled"
pass "all outputs disabled recovers the internal fallback"

# If the external-only rule cannot be parked, the guard must abort without
# leaving the only visible panel behind a rule that a reload can apply.
if [[ $EUID -ne 0 ]]; then
  reset_state
  mkdir -p "$home/.local/state/omarchy/toggles/hypr"
  printf 'hl.monitor({ output = "eDP-1", disabled = true })\n' \
    >"$home/.local/state/omarchy/toggles/hypr/internal-monitor-disable.lua"
  jq 'map(if .name == "eDP-1" then .disabled = true | .width = 0 | .height = 0 else . end)' \
    "$monitors" >"$monitors.tmp" && mv -f "$monitors.tmp" "$monitors"
  printf 'VCP D6 SNC x04\nVCP D6 SNC x04\nVCP D6 SNC x04\nVCP D6 SNC x04\n' >"$ddc_sequence"
  chmod 500 "$state"
  run_guard --once >"$guard_log" 2>&1
  run_rc=$?
  chmod 700 "$state"
  [[ $run_rc != 0 ]] || fail "state-write failure is reported"
  assert_enabled eDP-1
  assert_enabled HDMI-A-1
  assert_state_absent
  pass "a state-write failure leaves a visible fallback"
fi

# Dry-run is read-only, but it still probes DDC and says what it would do.
reset_state
printf 'VCP D6 SNC x04\nVCP D6 SNC x04\nVCP D6 SNC x04\n' >"$ddc_sequence"
run_guard --once --dry-run >"$guard_log" 2>&1
assert_enabled HDMI-A-1
assert_state_absent
[[ ! -s $actions ]] || fail "dry-run leaves Hyprland untouched"
[[ ! -e $state/ddc-ok/HDMI-A-1 ]] || fail "dry-run does not write a DDC marker"
[[ $(cat "$ddc_counter" 2>/dev/null || echo 0) -ge 1 ]] ||
  fail "dry-run performs a read-only DDC probe"
grep -F 'dry-run: would disable HDMI-A-1' "$guard_log" >/dev/null ||
  fail "dry-run reports the action it would take"
pass "dry-run probes without changing Hyprland or guard state"

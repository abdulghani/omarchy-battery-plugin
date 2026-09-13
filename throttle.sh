#!/usr/bin/env bash
# Cap every CPU core at its most efficient speed, or lift the cap again.
#
#   throttle.sh on        cap every core and remember the switch as on
#   throttle.sh off       lift the cap and remember the switch as off
#   throttle.sh restore   reapply the cap if the switch was left on
#   throttle.sh status    print state lines for sample.sh:
#
#     cpu            yes|no     (does the kernel expose per-core speed caps)
#     cpuwritable    yes|no     (are they group-writable)
#     cpucap         <kHz>      (the speed "on" caps cores at; highest across cores)
#     throttle       on|off     (is every core at or below its cap right now)
#     throttlesaved  on|off     (the switch's remembered position)
#
# The caps are root-owned; the tmpfiles rule omarchy-battery-cpu.conf makes
# them group-writable by wheel. Without it, on and off exit non-zero.

set -uo pipefail
export LC_ALL=C

cpufreq=/sys/devices/system/cpu/cpufreq
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/abdulghani.battery"
state_file="$state_dir/cpu-throttle"

# Lifting the cap writes a value above any real frequency rather than the
# hardware maximum. The kernel keeps the request as written and clamps the
# limit to whatever maximum is in force, so turbo switched on later (the
# performance profile does) is not pinned under the non-turbo top speed.
# 2147483647 is the largest value a frequency limit request holds.
unlimited=2147483647

shopt -s nullglob
policies=("$cpufreq"/policy*)

read_or() { [ -r "$1" ] && cat "$1" 2>/dev/null || echo "$2"; }

# The most efficient speed a core has: amd-pstate reports the lowest
# frequency at which performance still scales linearly with power, and below
# it the work just takes longer for no saving. Without that, half the core's
# top speed.
cap_for() {
  local nonlinear
  nonlinear=$(read_or "$1/amd_pstate_lowest_nonlinear_freq" 0)
  if [ "$nonlinear" -gt 0 ] 2>/dev/null; then
    echo "$nonlinear"
  else
    echo $(( $(read_or "$1/cpuinfo_max_freq" 0) / 2 ))
  fi
}

saved() { [ "$(read_or "$state_file" off)" = on ] && echo on || echo off; }

remember() { mkdir -p "$state_dir" && printf '%s\n' "$1" > "$state_file"; }

# stderr is redirected before stdout so a refused write stays quiet; the
# exit status still reports it.
write_max() { printf '%s' "$2" 2>/dev/null > "$1/scaling_max_freq"; }

apply() {
  local p failed=0
  for p in "${policies[@]}"; do
    if [ "$1" = on ]; then
      write_max "$p" "$(cap_for "$p")" || failed=1
    else
      # Fall back to the turbo top speed if a kernel refuses the large value.
      write_max "$p" "$unlimited" ||
        write_max "$p" "$(read_or "$p/amd_pstate_max_freq" "$(read_or "$p/cpuinfo_max_freq" 0)")" ||
        failed=1
    fi
  done
  return $failed
}

status() {
  if [ ${#policies[@]} -eq 0 ] || [ ! -e "${policies[0]}/scaling_max_freq" ]; then
    echo "cpu no"
    return
  fi

  echo "cpu yes"
  [ -w "${policies[0]}/scaling_max_freq" ] && echo "cpuwritable yes" || echo "cpuwritable no"

  local p cap highest=0 capped=on
  for p in "${policies[@]}"; do
    cap=$(cap_for "$p")
    [ "$cap" -gt "$highest" ] && highest=$cap
    [ "$(read_or "$p/scaling_max_freq" 0)" -le "$cap" ] || capped=off
  done

  echo "cpucap $highest"
  echo "throttle $capped"
  echo "throttlesaved $(saved)"
}

case "${1:-status}" in
  on | off)
    apply "$1" || exit 1
    remember "$1"
    ;;
  restore)
    [ "$(saved)" = on ] || exit 0
    apply on
    ;;
  status)
    status
    ;;
  *)
    echo "Usage: throttle.sh on|off|restore|status" >&2
    exit 2
    ;;
esac

#!/usr/bin/env bash
# One reading of the battery's charge control state and health, as flat
# whitespace-delimited lines. Reads only; every write is done by the widget.
#
#   path      <sysfs dir of the battery in use>
#   writable  yes|no                       (are the control attributes group-writable)
#   start     <percent>                    (recharge below this)
#   end       <percent>                    (stop charging here)
#   behaviour <auto|inhibit-charge|force-discharge>
#   supports  <space-separated behaviours the firmware accepts>
#   capacity  <percent>
#   status    <Charging|Discharging|Not charging|Full|Unknown>
#   power     <microwatts>
#   health    <percent of design capacity>
#   cycles    <count>
#   full      <energy_full in uWh>   design <energy_full_design in uWh>
#   onac      yes|no                     (external power connected)
#   profile   <name> <0|1>               (one per available power profile)
#   cpu, cpuwritable, cpucap, throttle, throttlesaved   (see throttle.sh)

set -uo pipefail
export LC_ALL=C

# First battery that actually exposes a charge cap.
bat=""
for b in /sys/class/power_supply/*; do
  [ -r "$b/type" ] || continue
  [ "$(cat "$b/type" 2>/dev/null)" = "Battery" ] || continue
  [ -e "$b/charge_control_end_threshold" ] || continue
  bat="$b"
  break
done

if [ -z "$bat" ]; then
  echo "path"
  echo "writable no"
  exit 0
fi

read_or() { [ -r "$1" ] && cat "$1" 2>/dev/null || echo "$2"; }

echo "path $bat"
[ -w "$bat/charge_control_end_threshold" ] && echo "writable yes" || echo "writable no"

echo "start $(read_or "$bat/charge_control_start_threshold" 0)"
echo "end $(read_or "$bat/charge_control_end_threshold" 100)"

# charge_behaviour prints every option with the active one in [brackets].
if [ -r "$bat/charge_behaviour" ]; then
  raw=$(cat "$bat/charge_behaviour")
  echo "behaviour $(printf '%s\n' "$raw" | grep -o '\[[^]]*\]' | tr -d '[]')"
  echo "supports $(printf '%s\n' "$raw" | tr -d '[]')"
fi

echo "capacity $(read_or "$bat/capacity" 0)"
echo "status $(read_or "$bat/status" Unknown | tr ' ' '-')"
echo "power $(read_or "$bat/power_now" 0)"
echo "cycles $(read_or "$bat/cycle_count" 0)"

full=$(read_or "$bat/energy_full" 0)
design=$(read_or "$bat/energy_full_design" 0)
echo "full $full"
echo "design $design"
if [ "$design" -gt 0 ] 2>/dev/null; then
  echo "health $(awk -v f="$full" -v d="$design" 'BEGIN{printf "%.1f", 100*f/d}')"
fi

# ---- Power profiles --------------------------------------------------------
# Which slot a change should be remembered under. Omarchy keeps a separate
# profile for AC and for battery, so a change has to name the one in force.
if omarchy power present >/dev/null 2>&1; then
  echo "onac yes"
else
  echo "onac no"
fi

# "<name>\t<1 if active>" per line.
omarchy powerprofiles list --active-state 2>/dev/null |
  awk -F'\t' 'NF >= 2 { print "profile", $1, $2 }'

# ---- CPU throttle ----------------------------------------------------------
# throttle.sh owns what the cap is, so the reading comes from there too.
"$(dirname "$0")/throttle.sh" status

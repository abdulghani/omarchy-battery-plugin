# Battery Charge Limit — Omarchy bar widget

An [AlDente](https://apphousekitchen.com/aldente-overview/)-style charge
limiter for [Omarchy](https://omarchy.org/), for laptops whose firmware
exposes charge thresholds (ThinkPads, most Lenovo/ASUS/Dell machines).

Keeping a lithium battery parked at 100% is what wears it out. This widget
caps the charge, and lets the **firmware** hold the band — nothing polls in the
background, and the limit survives reboots, logouts, and the widget itself
being disabled.

```
bar:     ▰▰▰▰▰▰▱▱▮ 89%   <- drawn battery, filled to the real charge
        ⚡▰▰▰▰▰▰▱▱▮ 89%   <- bolt appears while the charger is connected

popup
  󰂀  96%   Discharging
      8.8 W   ·   limited to 80%
  ─────────────────────────────────
  SAILING BAND
  Stop charging at              80%
  [────────────────●────]
  Recharge below                75%
  [───────────────●─────]
  ─────────────────────────────────
  BEHAVIOUR
  [ Auto ]  [ Hold ]  [ Discharge ]
  Charging is paused. The laptop runs
  from the charger, but the battery is
  left where it is.
  ─────────────────────────────────
  CHARGER
  Adapter                  Connected
  Battery                  Idle   0.0 W
  ─────────────────────────────────
  POWER PROFILE
  [ 󰌪 Saver ] [ 󰊚 Balanced ] [ 󰓅 Perf ]
  Remembered for battery.
  ─────────────────────────────────
  CPU
  Throttle CPU                  [  ●]
  Every core is capped at 1.1 GHz.
  ─────────────────────────────────
  HEALTH
  Capacity remaining          88.4%
  Full charge      34.8 / 39.4 Wh
  Cycles                         52
```

The bar carries the battery and its charge: a drawn outline whose fill tracks
the level continuously, with the percentage beside it. It is drawn rather than set from a font glyph because Nerd Font
battery icons step in tenths, so a glyph can only show the charge rounded to
the nearest 10%. It turns your theme's urgent color below 15%, and a bolt appears to its left
while the adapter is connected. The bolt is drawn too, not set from a font
glyph, so it cannot land as a missing-glyph box on a bar font without the icon
— and it sits outside the outline, where it stays legible at every charge
level instead of fighting the fill behind it.

**Sailing band** — the pair of thresholds. The firmware stops charging at the
upper bound and does not resume until you fall below the lower one, so the
battery drifts inside the band instead of trickle-topping at a single point.
75–80% is a good default for a mostly-docked laptop.

**Behaviour** — whichever modes your firmware reports:

| | |
|---|---|
| **Auto** | Normal charging, within the band |
| **Hold** | `inhibit-charge` — pause charging without draining |
| **Discharge** | `force-discharge` — run off the battery while plugged in |

The selected mode explains itself in a line beneath the chips, so you do not
have to remember which is which. Discharge keeps the urgent color, since it is
the one that surprises people.

**Charger** — whether the adapter is connected and which way power is moving
through the battery. Unplugged, it also shows the machine's total draw, since
everything the laptop uses is coming out of the battery.

> Many laptops, including ThinkPads, expose **no sensor on the AC adapter** —
> only whether it is plugged in. Where that is the case, draw from the charger
> cannot be measured and the panel says so rather than inventing a number.

**Power profile** — saver / balanced / performance, through
`omarchy-powerprofiles-set`. Omarchy keeps a **separate profile for AC and for
battery**, so the widget sets the slot currently in force and the choice is
restored whenever you switch back to that power source. The chips are built
from whatever `omarchy powerprofiles list` reports, so a machine exposing
different profiles gets its own set. Hidden entirely if fewer than two exist.

**CPU throttle** — one switch that caps every core's top speed. On
`amd-pstate` machines the cap is the driver's *lowest non-linear frequency*,
the point below which a core only gets slower rather than more efficient
(1.1 GHz on a Ryzen 5 PRO 6650U); elsewhere it is half the core's top speed.
Switching off lifts the cap entirely instead of writing today's top speed
back, so turbo enabled later — the performance profile does that — is not
pinned underneath it.

> **Set expectations.** The power-saver profile already picks the most frugal
> energy preference and turns turbo off. The cap adds to that, and it pays
> under **sustained** load — builds, video calls, a browser full of busy tabs —
> where it trades speed for watts, heat, and fan noise. Light, bursty work
> already finishes quickly and drops back to idle, so the saving there is small.

The kernel forgets the cap at reboot; the widget remembers the switch and puts
the cap back when it starts. Power profiles leave the speed cap alone, so the
switch and the profile combine rather than fight.

**Health** — remaining capacity against design, energy, and cycle count.

## Requirements

A battery exposing `charge_control_end_threshold` under
`/sys/class/power_supply/`. Check yours:

```bash
ls /sys/class/power_supply/BAT*/charge_control_end_threshold
```

Nothing there means your firmware does not support this and the widget will
hide itself. `charge_control_start_threshold` and `charge_behaviour` are used
when present; without them the band collapses to a simple cap and the
behaviour switch is hidden.

The CPU switch needs a cpufreq driver exposing per-policy speed caps, which
nearly every laptop has:

```bash
ls /sys/devices/system/cpu/cpufreq/policy*/scaling_max_freq
```

## Install

```bash
omarchy plugin add https://github.com/abdulghani/omarchy-battery-plugin.git --enable --yes
```

Then grant write access — the shell runs as your user and the attributes are
root-owned:

```bash
sudo install -m 0644 -o root -g root \
  ~/.config/omarchy/plugins/abdulghani.battery/omarchy-battery-charge.conf \
  ~/.config/omarchy/plugins/abdulghani.battery/omarchy-battery-cpu.conf \
  /etc/tmpfiles.d/
sudo systemd-tmpfiles --create \
  /etc/tmpfiles.d/omarchy-battery-charge.conf \
  /etc/tmpfiles.d/omarchy-battery-cpu.conf
omarchy restart shell
```

`omarchy-battery-charge.conf` makes exactly three attributes group-writable by
`wheel`: `charge_control_end_threshold`, `charge_control_start_threshold`, and
`charge_behaviour`. `omarchy-battery-cpu.conf` does the same for each CPU
policy's `scaling_max_freq` and nothing else — governors, energy preferences,
and turbo stay root-only. Both reapply on every boot. Each is optional: skip
one and that part of the panel runs read-only, and says so.

> **Trade-off worth understanding:** any process running as you can then change
> your charge thresholds and cap your CPU speed. That is the price of controls
> that respond without a password prompt. If you would rather authenticate
> each change, drop the tmpfiles rules and drive the attributes through
> `pkexec` instead.

## Remove

```bash
omarchy plugin remove abdulghani.battery --yes
sudo rm /etc/tmpfiles.d/omarchy-battery-charge.conf /etc/tmpfiles.d/omarchy-battery-cpu.conf
rm -rf ~/.local/state/abdulghani.battery
omarchy restart shell
```

Thresholds live in firmware, so removing the widget does **not** reset them.
Clear the limit first, or afterwards:

```bash
echo 100 | sudo tee /sys/class/power_supply/BAT0/charge_control_end_threshold
echo 0   | sudo tee /sys/class/power_supply/BAT0/charge_control_start_threshold
echo auto | sudo tee /sys/class/power_supply/BAT0/charge_behaviour
```

A CPU cap left on lasts until the next reboot. To lift it straight away:

```bash
echo 2147483647 | sudo tee /sys/devices/system/cpu/cpufreq/policy*/scaling_max_freq
```

## How it works

`sample.sh` reads the battery's control attributes and health into flat lines;
the QML side parses them and writes changes straight back to sysfs. There is no
daemon and no polling loop maintaining the limit — the kernel exposes the
firmware's own thresholds, and the firmware enforces them.

Power profiles go through `omarchy-powerprofiles-set` rather than
`powerprofilesctl`, so Omarchy's own per-power-source memory keeps working and
this widget and Omarchy's power widget never disagree.

`throttle.sh` owns the CPU cap: `on` writes each policy's cap to
`scaling_max_freq`, `off` writes a value above any real frequency (the kernel
clamps it to whatever maximum is in force), and `status` reports the state for
`sample.sh`. The switch's position is kept in
`~/.local/state/abdulghani.battery/cpu-throttle`, and `throttle.sh restore`
reapplies it once when the widget starts.

Polling is only for display: 15s on the bar, 2s while the popup is open. After
a write the panel holds the slider's position for 900ms before trusting a
reading again, so a poll racing the write cannot snap the handle back.

Raising the cap below the current recharge point would leave the firmware with
an impossible band, so the lower bound is pulled down with it.

## License

MIT — see [LICENSE](LICENSE).

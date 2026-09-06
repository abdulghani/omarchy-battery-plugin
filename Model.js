.pragma library

// One sample.sh run into a plain object. Unknown keys are ignored so the
// script can grow new lines without breaking an older panel.
function parse(text) {
  var out = {
    path: "", writable: false,
    start: 0, end: 100,
    behaviour: "auto", supports: [],
    capacity: 0, status: "Unknown", power: 0,
    cycles: 0, full: 0, design: 0, health: 0,
    onAc: false, profiles: [], activeProfile: ""
  }

  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var f = lines[i].trim().split(/\s+/)
    if (f.length < 2) continue

    switch (f[0]) {
    case "path":      out.path = f[1]; break
    case "writable":  out.writable = f[1] === "yes"; break
    case "start":     out.start = parseInt(f[1], 10) || 0; break
    case "end":       out.end = parseInt(f[1], 10) || 100; break
    case "behaviour": out.behaviour = f[1]; break
    case "supports":  out.supports = f.slice(1); break
    case "capacity":  out.capacity = parseInt(f[1], 10) || 0; break
    case "status":    out.status = f[1].replace(/-/g, " "); break
    case "power":     out.power = Number(f[1]) || 0; break
    case "cycles":    out.cycles = parseInt(f[1], 10) || 0; break
    case "full":      out.full = Number(f[1]) || 0; break
    case "design":    out.design = Number(f[1]) || 0; break
    case "health":    out.health = Number(f[1]) || 0; break
    case "onac":      out.onAc = f[1] === "yes"; break
    case "profile":
      out.profiles.push(f[1])
      if (f[2] === "1") out.activeProfile = f[1]
      break
    }
  }
  return out
}

// Nerd Font battery glyph for a charge level, matching how Omarchy's own
// power widget steps through its icons.
function levelIcon(percent, charging) {
  if (charging) return "󰂄"          // nf-md-battery_charging
  var steps = [
    "󰁺", "󰁻", "󰁼", "󰁽", "󰁾",
    "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"
  ]
  var i = Math.max(0, Math.min(steps.length - 1, Math.round(percent / 10) - 1))
  return steps[i]
}

function behaviourLabel(behaviour) {
  if (behaviour === "inhibit-charge") return "Hold"
  if (behaviour === "force-discharge") return "Discharge"
  return "Auto"
}

// Watts, from the kernel's microwatts.
function watts(microwatts) {
  return (Number(microwatts) || 0) / 1000000
}

function wh(microwatthours) {
  return (Number(microwatthours) || 0) / 1000000
}

// A limit only means something while it is below a full charge.
function limitActive(end) {
  return end > 0 && end < 100
}

// Keep the recharge point below the cap, with a little hysteresis, so the
// firmware is never asked for an impossible band.
function clampStart(start, end) {
  return Math.max(0, Math.min(start, end - 1))
}

// Icons match Omarchy's own power widget so the two read as one system.
function profileIcon(name) {
  if (name === "power-saver") return "󰌪"
  if (name === "balanced") return "󰊚"
  if (name === "performance") return "󰓅"
  return "󰂄"
}

function profileLabel(name) {
  if (name === "power-saver") return "Saver"
  if (name === "balanced") return "Balanced"
  if (name === "performance") return "Performance"
  return name
}

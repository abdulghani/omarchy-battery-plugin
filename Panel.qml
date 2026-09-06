import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Charge-limit control for laptops whose firmware exposes charge thresholds:
// a sailing band the firmware maintains itself, a charge-behaviour switch, and
// battery health. Writes go straight to sysfs — the attributes are made
// group-writable by the tmpfiles rule this plugin ships.
Panel {
  id: root
  moduleName: "abdulghani.battery"

  readonly property string scriptPath: Qt.resolvedUrl("sample.sh").toString().replace(/^file:\/\//, "")
  readonly property color fg: bar ? bar.foreground : Color.foreground

  property string batteryPath: ""
  property bool writable: false
  property int startThreshold: 0
  property int endThreshold: 100
  property string behaviour: "auto"
  property var supported: []
  property int capacity: 0
  property string status: "Unknown"
  property real powerNow: 0
  property int cycles: 0
  property real energyFull: 0
  property real energyDesign: 0
  property real health: 0
  property bool sampled: false

  property bool onAc: false
  property var profiles: []
  property string activeProfile: ""
  // Held while a change is in flight, so the chip lights up on the click
  // rather than waiting for the next poll to confirm it.
  property string pendingProfile: ""
  readonly property string shownProfile: pendingProfile !== "" ? pendingProfile : activeProfile

  readonly property var profileOptions: {
    var out = []
    for (var i = 0; i < profiles.length; i++) {
      out.push({
        value: profiles[i],
        label: Model.profileLabel(profiles[i]),
        icon: Model.profileIcon(profiles[i])
      })
    }
    return out
  }

  // While a slider is being dragged the panel shows the handle's position
  // rather than the last reading, so a poll landing mid-drag cannot yank it.
  property int pendingStart: -1
  property int pendingEnd: -1

  readonly property int shownStart: pendingStart >= 0 ? pendingStart : startThreshold
  readonly property int shownEnd: pendingEnd >= 0 ? pendingEnd : endThreshold

  readonly property bool present: batteryPath !== ""
  readonly property bool charging: status === "Charging"
  readonly property bool limited: Model.limitActive(endThreshold)
  readonly property string behaviourLabel: Model.behaviourLabel(behaviour)

  readonly property var behaviourOptions: {
    var out = []
    for (var i = 0; i < supported.length; i++) {
      var v = supported[i]
      out.push({ value: v, label: Model.behaviourLabel(v) })
    }
    return out
  }

  function sample() {
    if (!readProc.running) readProc.running = true
  }

  function applySample(text) {
    var s = Model.parse(text)
    root.batteryPath = s.path
    root.writable = s.writable
    root.startThreshold = s.start
    root.endThreshold = s.end
    root.behaviour = s.behaviour
    root.supported = s.supports
    root.capacity = s.capacity
    root.status = s.status
    root.powerNow = s.power
    root.cycles = s.cycles
    root.energyFull = s.full
    root.energyDesign = s.design
    root.health = s.health
    root.onAc = s.onAc
    // Keep the last known list if a reading came back empty, so the chips do
    // not vanish when powerprofilesctl is briefly unavailable.
    if (s.profiles.length > 0) {
      root.profiles = s.profiles
      root.activeProfile = s.activeProfile
    }
    root.sampled = true
  }

  // Each write is its own short-lived process. Chaining through one Process
  // would drop a change made while the previous one was still running.
  function writeAttribute(name, value) {
    if (!root.writable || !root.batteryPath) return
    writeProc.command = ["/bin/sh", "-c",
      "printf '%s' " + shellQuote(String(value)) + " > " + shellQuote(root.batteryPath + "/" + name)]
    writeProc.running = true
  }

  function shellQuote(value) {
    return "'" + String(value).replace(/'/g, "'\\''") + "'"
  }

  function setEnd(value) {
    var end = Math.max(1, Math.min(100, Math.round(value)))
    root.pendingEnd = end
    root.endThreshold = end
    // The firmware rejects a band whose recharge point is not below the cap,
    // so pull the start down with the cap rather than letting the pair go bad.
    if (root.startThreshold >= end) setStart(end - 1)
    writeAttribute("charge_control_end_threshold", end)
    settleTimer.restart()
  }

  function setStart(value) {
    var start = Model.clampStart(Math.round(value), root.endThreshold)
    root.pendingStart = start
    root.startThreshold = start
    writeAttribute("charge_control_start_threshold", start)
    settleTimer.restart()
  }

  // Omarchy remembers a profile per power source, so the change has to name
  // the slot in force rather than just setting the daemon's current profile.
  function setProfile(value) {
    if (!value || value === root.activeProfile || profileProc.running) return
    root.pendingProfile = value
    profileProc.command = ["omarchy-powerprofiles-set", root.onAc ? "ac" : "battery", value]
    profileProc.running = true
  }

  function setBehaviour(value) {
    if (value === root.behaviour) return
    root.behaviour = value
    writeAttribute("charge_behaviour", value)
    settleTimer.restart()
  }

  visible: present
  implicitWidth: present ? button.implicitWidth : 0
  implicitHeight: present ? button.implicitHeight : 0

  Process {
    id: readProc
    command: [root.scriptPath]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applySample(text)
    }
  }

  Process { id: writeProc }

  Process {
    id: profileProc
    onExited: {
      root.pendingProfile = ""
      root.sample()
    }
  }

  // Let the write land in the firmware before trusting a reading again, so a
  // poll racing the write cannot briefly show the old value back.
  Timer {
    id: settleTimer
    interval: 900
    onTriggered: {
      root.pendingStart = -1
      root.pendingEnd = -1
      root.sample()
    }
  }

  Timer {
    interval: root.opened ? 2000 : 15000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.sample()
  }

  // ---- Bar button ----------------------------------------------------------

  // The battery is drawn rather than set from a font glyph. Nerd Font battery
  // icons step in tenths, so a glyph can only ever show the charge rounded to
  // the nearest 10%; a drawn bar fills continuously with the real figure.
  readonly property real batteryFraction: Math.max(0, Math.min(1, capacity / 100))
  readonly property bool batteryLow: capacity <= 15 && !charging

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    horizontalMargin: 6
    labelVisible: false
    active: root.batteryLow || (!root.writable && root.present)
    // Non-empty so WidgetButton keeps the slot visible; nothing paints it.
    text: " "
    tooltipText: root.present
      ? (root.capacity + "%  " + root.status
         + "   ·   limit " + root.startThreshold + "–" + root.endThreshold + "%"
         + "   ·   " + root.behaviourLabel
         + (root.writable ? "" : "   ·   read-only"))
      : ""

    fixedWidth: glyph.implicitWidth + scaledHorizontalMargin * 2
    fixedHeight: -1

    readonly property color inkColor: button.active ? button.activeColor : button.foreground

    Item {
      id: glyph
      anchors.centerIn: parent

      // Sized off the bar so it keeps its proportions on a rescaled bar, and
      // laid out on whole pixels so the 1px outline stays crisp.
      readonly property real bodyHeight: Math.max(9, Math.round(button.barSize * 0.46))
      readonly property real bodyWidth: Math.round(bodyHeight * 1.95)
      readonly property real stroke: Math.max(1, Math.round(bodyHeight * 0.1))
      readonly property real capWidth: Math.max(1, Math.round(bodyHeight * 0.14))
      readonly property real capHeight: Math.max(2, Math.round(bodyHeight * 0.42))
      readonly property real capGap: Math.max(1, Math.round(bodyHeight * 0.09))
      // Bolt shown while the adapter is connected. It sits outside the
      // outline: drawn inside, it would be illegible against the fill at some
      // charge levels and against the empty body at others.
      readonly property real boltHeight: Math.round(bodyHeight * 0.95)
      readonly property real boltWidth: Math.round(boltHeight * 0.5)
      readonly property real boltGap: Math.max(1, Math.round(bodyHeight * 0.16))
      readonly property real boltSlot: root.onAc ? boltWidth + boltGap : 0
      // Clear space between the outline and the fill, so the two never merge.
      readonly property real padding: Math.max(1, Math.round(stroke))

      implicitWidth: boltSlot + bodyWidth + capGap + capWidth
      implicitHeight: bodyHeight

      // Drawn rather than set from a font glyph, so it cannot land as a
      // missing-glyph box on a bar font without the icon.
      Canvas {
        id: bolt
        visible: root.onAc
        width: glyph.boltWidth
        height: glyph.boltHeight
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter

        // Canvas does not repaint on a bound colour changing, so track it.
        property color ink: button.inkColor
        onInkChanged: requestPaint()
        onVisibleChanged: if (visible) requestPaint()

        onPaint: {
          var ctx = getContext("2d")
          ctx.reset()
          var w = width, h = height
          ctx.beginPath()
          ctx.moveTo(0.62 * w, 0)
          ctx.lineTo(0.16 * w, 0.57 * h)
          ctx.lineTo(0.45 * w, 0.57 * h)
          ctx.lineTo(0.38 * w, h)
          ctx.lineTo(0.84 * w, 0.43 * h)
          ctx.lineTo(0.55 * w, 0.43 * h)
          ctx.closePath()
          ctx.fillStyle = ink
          ctx.fill()
        }
      }

      Rectangle {
        id: shell
        width: glyph.bodyWidth
        height: glyph.bodyHeight
        anchors.left: parent.left
        anchors.leftMargin: glyph.boltSlot
        anchors.verticalCenter: parent.verticalCenter
        color: "transparent"
        radius: Math.max(1, Math.round(glyph.bodyHeight * 0.22))
        border.width: glyph.stroke
        border.color: button.inkColor
        // The outline is the frame, so it reads lighter than the charge itself.
        opacity: 0.75

        Behavior on border.color { ColorAnimation { duration: 200 } }
      }

      // Charge level. Width is the only thing that moves; it animates so a
      // poll landing between readings slides rather than jumps.
      Rectangle {
        id: level
        readonly property real track: shell.width - (glyph.stroke + glyph.padding) * 2
        x: shell.x + glyph.stroke + glyph.padding
        width: Math.max(root.batteryFraction > 0 ? 1 : 0, track * root.batteryFraction)
        height: shell.height - (glyph.stroke + glyph.padding) * 2
        anchors.verticalCenter: shell.verticalCenter
        radius: Math.max(1, Math.round(height * 0.28))
        color: button.inkColor

        Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
        Behavior on color { ColorAnimation { duration: 200 } }
      }

      // Terminal nub on the right, the part that makes it read as a battery.
      Rectangle {
        width: glyph.capWidth
        height: glyph.capHeight
        anchors.left: shell.right
        anchors.leftMargin: glyph.capGap
        anchors.verticalCenter: shell.verticalCenter
        radius: Math.max(1, Math.round(glyph.capWidth * 0.4))
        color: button.inkColor
        opacity: 0.75

        Behavior on color { ColorAnimation { duration: 200 } }
      }
    }

    onPressed: function (b) { root.toggle() }
  }

  // ---- Popup ---------------------------------------------------------------

  component StatLine: Item {
    property string label: ""
    property string value: ""
    implicitHeight: Math.max(lineLabel.implicitHeight, lineValue.implicitHeight)

    Text {
      id: lineLabel
      textFormat: Text.PlainText
      text: parent.label
      color: Qt.darker(root.fg, 1.35)
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: lineValue
      textFormat: Text.PlainText
      text: parent.value
      color: root.fg
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened && root.present
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        // ---------- Hero ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroText.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: Model.levelIcon(root.capacity, root.charging)
            color: root.fg
            font.family: Style.font.family
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: heroText
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(12)
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              text: root.capacity + "%   " + root.status
              color: root.fg
              font.family: Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              text: Model.watts(root.powerNow).toFixed(1) + " W   ·   "
                + (root.limited ? "limited to " + root.endThreshold + "%" : "no limit")
              color: Qt.darker(root.fg, 1.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
              width: parent.width
            }
          }
        }

        // Shown instead of the controls when the sysfs attributes are not
        // writable — without the tmpfiles rule this panel can only read.
        Text {
          visible: root.sampled && !root.writable
          width: parent.width
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          text: "Charge control is read-only. Install the tmpfiles rule shipped "
            + "with this plugin, then log out and back in."
          color: root.bar ? root.bar.urgent : Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        PanelSeparator { foreground: root.fg }

        // ---------- Sailing band ----------
        PanelSectionHeader {
          text: "SAILING BAND"
          foreground: root.fg
          visible: root.writable
        }

        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.writable

          StatLine {
            width: parent.width
            label: "Stop charging at"
            value: root.shownEnd + "%"
          }

          Item {
            width: parent.width
            implicitHeight: Style.space(20)

            PanelSlider {
              anchors.fill: parent
              bar: root.bar
              minimum: 20
              maximum: 100
              step: 1
              integer: true
              value: root.shownEnd
              onMoved: function (v) { root.pendingEnd = Math.round(v) }
              onReleased: function (v) { root.setEnd(v) }
            }
          }

          StatLine {
            width: parent.width
            label: "Recharge below"
            value: root.shownStart + "%"
          }

          Item {
            width: parent.width
            implicitHeight: Style.space(20)

            PanelSlider {
              anchors.fill: parent
              bar: root.bar
              minimum: 0
              maximum: 99
              step: 1
              integer: true
              value: root.shownStart
              onMoved: function (v) { root.pendingStart = Math.round(v) }
              onReleased: function (v) { root.setStart(v) }
            }
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: "The firmware holds this band on its own — nothing polls in "
              + "the background, and it survives reboots and this widget being closed."
            color: Qt.darker(root.fg, 1.8)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        PanelSeparator { foreground: root.fg; visible: root.writable }

        // ---------- Charge behaviour ----------
        PanelSectionHeader {
          text: "BEHAVIOUR"
          foreground: root.fg
          visible: root.writable && root.behaviourOptions.length > 1
        }

        ButtonGroup {
          width: parent.width
          visible: root.writable && root.behaviourOptions.length > 1
          options: root.behaviourOptions
          value: root.behaviour
          foreground: root.fg
          background: Color.popups.background
          accent: Color.accent
          fontSize: Style.font.bodySmall
          focusable: false
          onChanged: function (value) { root.setBehaviour(value) }
        }

        // Discharge is the one mode that surprises people, so it keeps the
        // urgent color; the rest read as ordinary help text.
        Text {
          visible: root.writable && root.behaviourOptions.length > 1
          width: parent.width
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          text: Model.behaviourDescription(root.behaviour)
          color: root.behaviour === "force-discharge"
            ? (root.bar ? root.bar.urgent : Color.urgent)
            : Qt.darker(root.fg, 1.8)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        PanelSeparator { foreground: root.fg }

        // ---------- Charger ----------
        PanelSectionHeader {
          text: "CHARGER"
          foreground: root.fg
        }

        Column {
          width: parent.width
          spacing: Style.space(5)

          StatLine {
            width: parent.width
            label: "Adapter"
            value: root.onAc ? "Connected" : "Disconnected"
          }

          StatLine {
            width: parent.width
            label: "Battery"
            value: Model.flowLabel(root.status, root.powerNow)
          }

          // Unplugged, everything the machine uses comes out of the battery,
          // so the battery's own output is the whole machine's draw. On the
          // adapter there is nothing to measure it with: this laptop exposes
          // no sensor on AC at all, only whether it is connected.
          StatLine {
            width: parent.width
            visible: !root.onAc
            label: "Machine draw"
            value: Model.watts(root.powerNow).toFixed(1) + " W"
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: root.onAc
              ? "This laptop reports no sensor on the adapter, only whether it is connected, so draw from the charger cannot be measured. Unplug and the battery's output is the machine's draw."
              : "Measured from the battery's output, which is everything the machine is using."
            color: Qt.darker(root.fg, 1.8)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        PanelSeparator { foreground: root.fg; visible: root.profileOptions.length > 1 }

        // ---------- Power profile ----------
        PanelSectionHeader {
          text: "POWER PROFILE"
          foreground: root.fg
          visible: root.profileOptions.length > 1
        }

        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: root.profileOptions.length > 1

          ButtonGroup {
            width: parent.width
            options: root.profileOptions
            value: root.shownProfile
            foreground: root.fg
            background: Color.popups.background
            accent: Color.accent
            fontSize: Style.font.bodySmall
            focusable: false
            onChanged: function (value) { root.setProfile(value) }
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: "Remembered for " + (root.onAc ? "AC" : "battery")
              + " and restored when you next switch to it."
            color: Qt.darker(root.fg, 1.8)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        PanelSeparator { foreground: root.fg }

        // ---------- Health ----------
        PanelSectionHeader {
          text: "HEALTH"
          foreground: root.fg
        }

        Column {
          width: parent.width
          spacing: Style.space(5)

          StatLine {
            width: parent.width
            label: "Capacity remaining"
            value: root.health.toFixed(1) + "%"
          }

          StatLine {
            width: parent.width
            label: "Full charge"
            value: Model.wh(root.energyFull).toFixed(1) + " / "
              + Model.wh(root.energyDesign).toFixed(1) + " Wh"
          }

          StatLine {
            width: parent.width
            label: "Cycles"
            value: String(root.cycles)
          }
        }
      }
    }
  }
}

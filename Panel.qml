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

  readonly property real barIconSize: Style.bar.iconFont
  readonly property real barValueSize: Style.font.bodySmall

  // The cap is what this widget is for, so that is what the bar carries;
  // Omarchy's own power widget already shows the charge level.
  readonly property string barIcon: behaviour === "force-discharge" ? "󰶈"
    : behaviour === "inhibit-charge" ? "󰂃"
    : limited ? "󰂄" : Model.levelIcon(capacity, charging)

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    horizontalMargin: 6
    labelVisible: false
    active: !root.writable && root.present
    text: root.barIcon + " " + root.endThreshold
    tooltipText: root.present
      ? (root.capacity + "%  " + root.status
         + "   ·   limit " + root.startThreshold + "–" + root.endThreshold + "%"
         + "   ·   " + root.behaviourLabel
         + (root.writable ? "" : "   ·   read-only"))
      : ""

    readonly property bool stacked: root.bar ? root.bar.vertical : false
    fixedWidth: stacked ? -1 : horizontalRow.implicitWidth + scaledHorizontalMargin * 2
    fixedHeight: stacked ? verticalColumn.implicitHeight + scaledVerticalPadding * 2 : -1

    Row {
      id: horizontalRow
      visible: !button.stacked
      anchors.centerIn: parent
      spacing: Style.spaceReal(3)

      Text {
        textFormat: Text.PlainText
        text: root.barIcon
        color: button.active ? button.activeColor : button.foreground
        font.family: button.fontFamily
        font.pixelSize: root.barIconSize
        renderType: Text.NativeRendering
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        textFormat: Text.PlainText
        text: root.limited ? root.endThreshold + "%" : root.capacity + "%"
        color: button.active ? button.activeColor : button.foreground
        font.family: button.fontFamily
        font.pixelSize: root.barValueSize
        renderType: Text.NativeRendering
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Column {
      id: verticalColumn
      visible: button.stacked
      anchors.centerIn: parent
      spacing: 0

      Text {
        textFormat: Text.PlainText
        text: root.barIcon
        color: button.active ? button.activeColor : button.foreground
        font.family: button.fontFamily
        font.pixelSize: root.barIconSize
        renderType: Text.NativeRendering
        anchors.horizontalCenter: parent.horizontalCenter
      }

      Text {
        textFormat: Text.PlainText
        text: String(root.limited ? root.endThreshold : root.capacity)
        color: button.active ? button.activeColor : button.foreground
        font.family: button.fontFamily
        font.pixelSize: root.barValueSize
        renderType: Text.NativeRendering
        anchors.horizontalCenter: parent.horizontalCenter
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

        Text {
          visible: root.behaviour === "force-discharge"
          width: parent.width
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          text: "Discharging on AC. The battery is draining even though the "
            + "charger is connected."
          color: root.bar ? root.bar.urgent : Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
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

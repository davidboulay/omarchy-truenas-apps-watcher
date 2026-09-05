import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// A drive bay in the bar. It stays a muted foreground while every app on the
// NAS is current, and turns the bar's attention color with a count the moment
// something has an upgrade waiting — a new catalog version, a newer image
// under the same version, or a container Portainer watches on TrueNAS's behalf.
Panel {
  id: nasPanel
  moduleName: "io.github.davidboulay.truenas-apps-watcher"
  ipcTarget: "truenas"
  manageIpc: false

  // Material Design Icons' NAS mark — a drive-bay enclosure — as carried by
  // the Nerd Font the bar already uses (nf-md-nas).
  readonly property string nasGlyph: String.fromCodePoint(0xF08F3)

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"

  property bool showSettings: false
  property bool cursorActive: false
  property int cursorIndex: 0

  // Draft connection details, live only while the settings view is open.
  property string editAddress: ""
  property string editApiKey: ""
  property bool editInsecure: true
  property string editPortainerAddress: ""
  property string editPortainerApiKey: ""

  readonly property var upgradeItems: nas.report.upgrades
  readonly property var imageItems: nas.report.images
  readonly property var containerItems: nas.report.containers
  readonly property var navRows: Model.navRows(nas.report, { installing: nas.installing })
  readonly property bool anyItems: nas.pendingTotal > 0

  // Every pending item here is actionable, so the badge is simply the count.
  readonly property int badgeCount: nas.pendingTotal
  readonly property bool attention: badgeCount > 0
  readonly property bool hideWhenUpToDate: setting("hideWhenUpToDate", false) === true

  readonly property string errorText: {
    var parts = []
    if (nas.lastError !== "") parts.push(nas.lastError)
    if (nas.containerError !== "") parts.push(nas.containerError)
    if (nas.actionError !== "") parts.push(nas.actionError)
    return parts.join("\n")
  }

  function itemNavIndex(section, index) {
    var offset = 0
    if (section === "image") offset = upgradeItems.length
    else if (section === "container") offset = upgradeItems.length + imageItems.length
    return 1 + offset + index
  }

  function rowAt(index) {
    if (index < 0 || index >= navRows.length) return null
    return navRows[index]
  }

  function clampCursor() {
    if (cursorIndex < 0) cursorIndex = 0
    if (cursorIndex >= navRows.length) cursorIndex = Math.max(0, navRows.length - 1)
  }

  function moveCursor(delta) {
    cursorActive = true
    cursorIndex = Math.max(0, Math.min(navRows.length - 1, cursorIndex + delta))
    scrollCursorIntoView()
  }

  function setCursor(index) {
    cursorActive = true
    cursorIndex = index
  }

  function activateCursor() {
    clampCursor()
    var row = rowAt(cursorIndex)
    if (!row) return
    if (row.kind === "check") nas.check(true)
    else if (row.kind === "apply") nas.installAll()
    else if (row.kind === "open") nas.openWebUi()
  }

  function scrollCursorIntoView() {
    if (!panelFlick) return
    Qt.callLater(function() {
      var item = cursorTarget
      if (!item) return
      var margin = Style.space(6)
      var point = item.mapToItem(panelFlick.contentItem, 0, 0)
      var top = point.y
      var bottom = top + item.height
      var viewTop = panelFlick.contentY
      var viewBottom = viewTop + panelFlick.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < viewTop + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > viewBottom - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  // Set by whichever row currently holds the cursor, so scrolling doesn't
  // have to walk the section columns to find it.
  property Item cursorTarget: null

  function openSettings() {
    nasPanel.editAddress = nas.address
    nasPanel.editApiKey = nas.apiKey
    nasPanel.editInsecure = nas.acceptInvalidCerts
    nasPanel.editPortainerAddress = nas.portainerAddress
    nasPanel.editPortainerApiKey = nas.portainerApiKey
    // Assign the fields rather than binding them: a field the user has typed
    // into no longer follows its binding, and the panel reopens often.
    if (addressField) addressField.text = nas.address
    if (apiKeyField) apiKeyField.text = nas.apiKey
    if (portainerAddressField) portainerAddressField.text = nas.portainerAddress
    if (portainerKeyField) portainerKeyField.text = nas.portainerApiKey
    nasPanel.showSettings = true
    Qt.callLater(function() { if (addressField) addressField.forceActiveFocus() })
  }

  function closeSettings() {
    nasPanel.showSettings = false
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function saveSettings() {
    if (!settingsDirty || !settingsValid) return
    nas.saveConfig({
      address: nasPanel.editAddress,
      apiKey: nasPanel.editApiKey,
      acceptInvalidCerts: nasPanel.editInsecure,
      portainerAddress: nasPanel.editPortainerAddress,
      portainerApiKey: nasPanel.editPortainerApiKey
    })
    closeSettings()
  }

  function trimmed(text) {
    return String(text || "").replace(/^\s+|\s+$/g, "")
  }

  readonly property bool settingsDirty: trimmed(editAddress) !== nas.address
    || trimmed(editApiKey) !== nas.apiKey
    || editInsecure !== nas.acceptInvalidCerts
    || trimmed(editPortainerAddress) !== nas.portainerAddress
    || trimmed(editPortainerApiKey) !== nas.portainerApiKey
  readonly property bool settingsValid: trimmed(editAddress) !== "" && trimmed(editApiKey) !== ""

  // Nothing to watch and nothing to configure yet is still worth a bar slot —
  // that is where the settings live. Only "everything is current" can hide.
  visible: !(hideWhenUpToDate && nas.configured && !attention && !nas.offline)
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    cursorIndex = 0
    if (panelFlick) panelFlick.contentY = 0
    nasPanel.showSettings = !nas.configured
    if (nasPanel.showSettings) openSettings()
    else if (nas.configured) nas.check(false)
    Qt.callLater(function() { if (!nasPanel.showSettings) keyCatcher.forceActiveFocus() })
  }
  onNavRowsChanged: clampCursor()

  Service {
    id: nas
    settings: nasPanel.settings
  }

  Connections {
    target: nas
    function onConfigSaved() { nasPanel.clampCursor() }
  }

  IpcHandler {
    target: nasPanel.ipcTarget
    function open(): void { nasPanel.open() }
    function close(): void { nasPanel.close() }
    function show(): void { nasPanel.open() }
    function hide(): void { nasPanel.close() }
    function toggle(): void { nasPanel.toggle() }
    // Syncs the app catalog first, so a version published minutes ago counts.
    function refresh(): string { nas.check(true); return "ok" }
    // Re-checks the unmanaged containers against their registries.
    function containers(): string { nas.checkContainers(); return "ok" }
    function install(): string { nas.installAll(); return "ok" }
    // Opens the popup on the connection form, the same as the cog or `s`.
    function settings(): void { nasPanel.open(); nasPanel.openSettings() }
    function status(): string { return nas.summary }
    function count(): string { return String(nas.pendingTotal) }
    // Overall completion percent while applying, or "-1" when idle.
    function progress(): string {
      if (!nas.installing || nas.installProgress < 0) return "-1"
      return String(Math.round(nas.installProgress * 100))
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: nasPanel.bar
    // A vertical bar is 28px wide — no room for a count beside the glyph, so
    // the tooltip carries it there.
    text: nasPanel.vertical || nasPanel.badgeCount === 0
      ? nasPanel.nasGlyph
      : nasPanel.nasGlyph + " " + nasPanel.badgeCount
    fontSize: Style.font.body
    active: nasPanel.attention
    dimmed: !nas.configured || nas.offline
    tooltipText: "TrueNAS — " + nas.summary
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) nas.check(true)
      else if (buttonCode === Qt.MiddleButton) nas.openWebUi()
      else nasPanel.toggle()
    }
  }

  readonly property bool vertical: bar ? bar.vertical : false

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: nasPanel
    bar: nasPanel.bar
    open: nasPanel.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(
      nasPanel.showSettings
        ? settingsColumn.implicitHeight
        : topBlock.implicitHeight + listColumn.implicitHeight + bottomBlock.implicitHeight
          + updatesLayout.spacing * 2,
      Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: nasPanel.showSettings
      onMoveRequested: function(dx, dy) {
        if (dy === 0) return
        if (!nasPanel.cursorActive) { nasPanel.cursorActive = true; return }
        nasPanel.moveCursor(dy > 0 ? 1 : -1)
      }
      onActivateRequested: if (nasPanel.cursorActive) nasPanel.activateCursor()
      onCloseRequested: nasPanel.close()
      onTabRequested: function(direction) { nasPanel.switchPanel(direction) }
      onTextKey: function(t) {
        var key = String(t || "").toLowerCase()
        if (key === "r") nas.check(true)
        else if (key === "a") nas.installAll()
        else if (key === "s") nasPanel.openSettings()
        else if (key === "o") nas.openWebUi()
      }

      // ------------------------------------------------------ updates view
      //
      // Only the list of updates scrolls. The summary, the check button and
      // the apply button stay pinned, so the one action worth taking is never
      // hidden below a long list.

      ColumnLayout {
        id: updatesLayout
        anchors.fill: parent
        visible: !nasPanel.showSettings
        spacing: Style.space(12)

        Column {
          id: topBlock
          Layout.fillWidth: true
          spacing: Style.space(12)

          Item {
            id: header
            width: parent.width
            implicitHeight: hero.implicitHeight

            PanelHero {
              id: hero
              width: parent.width
              title: "TrueNAS Apps"
              meta: nas.summary
              foreground: nasPanel.foreground
              fontFamily: nasPanel.fontFamily
              iconOpacity: nasPanel.attention ? 1.0 : 0.6
              iconComponent: Component {
                Text {
                  textFormat: Text.PlainText
                  text: nasPanel.nasGlyph
                  color: nasPanel.attention ? nasPanel.urgent : nasPanel.foreground
                  font.family: nasPanel.fontFamily
                  font.pixelSize: Style.font.display
                }
              }
              trailingControl: Component {
                PanelActionButton {
                  iconText: "󰒓"
                  tooltipText: "Settings"
                  foreground: nasPanel.foreground
                  fontFamily: nasPanel.fontFamily
                  onClicked: nasPanel.openSettings()
                }
              }
            }
          }

          // Off the home network (or the NAS is down): a normal state for a
          // laptop, not an error. Background retries keep running.
          Text {
            textFormat: Text.PlainText
            visible: nas.offline
            width: parent.width
            text: "TrueNAS not reachable — retrying automatically"
            color: nasPanel.dim
            font.family: nasPanel.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // The apps half can be perfectly healthy while Portainer is not.
          Text {
            textFormat: Text.PlainText
            visible: nas.containersOffline && !nas.offline
            width: parent.width
            text: "Portainer not reachable — containers not checked"
            color: nasPanel.dim
            font.family: nasPanel.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            textFormat: Text.PlainText
            visible: nasPanel.errorText !== ""
            width: parent.width
            text: nasPanel.errorText
            color: nasPanel.urgent
            font.family: nasPanel.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            textFormat: Text.PlainText
            visible: !nas.configured
            width: parent.width
            text: "Open Settings (s) and enter your TrueNAS address and an API key."
            color: nasPanel.dim
            font.family: nasPanel.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }

          // A manual check syncs the app catalog first — the same job TrueNAS
          // runs daily — so a version published minutes ago shows up now
          // rather than at the NAS's next scheduled look.
          Button {
            id: checkButton
            visible: nas.configured
            width: parent.width
            text: nas.busy && !nas.installing ? "Checking…" : "Check for updates"
            iconText: "󰑐"
            iconSpinning: nas.checking || nas.checkingContainers
            enabled: !nas.busy
            hasCursor: nasPanel.cursorActive && nasPanel.cursorIndex === 0
            foreground: nasPanel.foreground
            fontFamily: nasPanel.fontFamily
            bordered: true
            onHovered: function(on) { if (on) nasPanel.setCursor(0) }
            onClicked: {
              nas.check(true)
              nas.checkContainers()
            }
          }
        }

        Item {
          id: listArea
          visible: nasPanel.anyItems
          Layout.fillWidth: true
          Layout.fillHeight: true
          Layout.preferredHeight: listColumn.implicitHeight
          Layout.maximumHeight: listColumn.implicitHeight

        Flickable {
          id: panelFlick
          anchors.fill: parent
          contentWidth: width
          contentHeight: listColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          flickableDirection: Flickable.VerticalFlick
          interactive: contentHeight > height
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          Column {
            id: listColumn
            width: panelFlick.width
            spacing: Style.space(10)

            UpdateSection {
              title: "APP UPGRADES"
              items: nasPanel.upgradeItems
              section: "upgrade"
              note: "A newer catalog version — applied with app.upgrade."
            }

            UpdateSection {
              title: "IMAGE UPDATES"
              items: nasPanel.imageItems
              section: "image"
              note: "Same version, newer image — applied with app.pull_images."
            }

            UpdateSection {
              title: "CONTAINERS (PORTAINER)"
              items: nasPanel.containerItems
              section: "container"
              note: "Outside TrueNAS's apps — pulled and recreated in place."
            }
          }
        }

          // The list is cut wherever the scroll happens to land, which can be
          // through the middle of a section header. Fading the cut edges reads
          // as "more this way" instead of as a rendering fault.
          Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: Style.space(16)
            visible: panelFlick.contentY > 1
            gradient: Gradient {
              GradientStop { position: 0.0; color: Color.popups.background }
              GradientStop { position: 1.0; color: Util.alpha(Color.popups.background, 0) }
            }
          }

          Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: Style.space(16)
            visible: panelFlick.contentHeight - panelFlick.contentY - panelFlick.height > 1
            gradient: Gradient {
              GradientStop { position: 0.0; color: Util.alpha(Color.popups.background, 0) }
              GradientStop { position: 1.0; color: Color.popups.background }
            }
          }
        }

        Column {
          id: bottomBlock
          Layout.fillWidth: true
          spacing: Style.space(10)

          PanelSeparator {
            visible: nasPanel.anyItems
            foreground: nasPanel.foreground
          }

          // Progress replaces the apply button while updates are applied.
          Column {
            visible: nas.installing
            width: parent.width
            spacing: Style.space(6)

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: nas.installProgress >= 0
                ? "Applying updates… " + Math.round(nas.installProgress * 100) + "%"
                : "Applying updates…"
              color: nasPanel.foreground
              font.family: nasPanel.fontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }

            Text {
              textFormat: Text.PlainText
              visible: nas.installingTitle !== ""
              width: parent.width
              text: nas.installingTitle
              color: nasPanel.dim
              font.family: nasPanel.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            Item {
              width: parent.width
              implicitHeight: Style.space(8)

              Rectangle {
                id: barTrack
                anchors.fill: parent
                radius: height / 2
                color: Util.alpha(nasPanel.foreground, 0.12)
              }

              Rectangle {
                anchors.left: barTrack.left
                anchors.verticalCenter: barTrack.verticalCenter
                height: barTrack.height
                radius: barTrack.radius
                color: nasPanel.foreground
                width: nas.installProgress >= 0
                  ? Math.max(barTrack.height, barTrack.width * nas.installProgress)
                  : barTrack.width

                Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }

                // No percentage from the job for this one — pulse so the bar
                // reads as "working", not "stuck at full".
                SequentialAnimation on opacity {
                  running: nas.installing && nas.installProgress < 0
                  loops: Animation.Infinite
                  alwaysRunToEnd: true
                  NumberAnimation { from: 1.0; to: 0.4; duration: 900; easing.type: Easing.InOutSine }
                  NumberAnimation { from: 0.4; to: 1.0; duration: 900; easing.type: Easing.InOutSine }
                }
              }
            }
          }

          // One at a time: parallel upgrades would compete for the same Docker
          // daemon and the same pool datasets. Disabled while unreachable —
          // the list is then stale data from the last good check.
          Button {
            id: applyButton
            visible: nasPanel.badgeCount > 0 && !nas.installing
            width: parent.width
            text: "Apply " + nasPanel.badgeCount + " update" + (nasPanel.badgeCount === 1 ? "" : "s")
            iconText: "󰚰"
            enabled: !nas.offline && !nas.busy
            hasCursor: nasPanel.cursorActive && nasPanel.rowAt(nasPanel.cursorIndex)
              && nasPanel.rowAt(nasPanel.cursorIndex).kind === "apply"
            selected: true
            foreground: nasPanel.foreground
            fontFamily: nasPanel.fontFamily
            bordered: true
            onHovered: function(on) {
              if (!on) return
              for (var i = 0; i < nasPanel.navRows.length; i++) {
                if (nasPanel.navRows[i].kind === "apply") { nasPanel.setCursor(i); return }
              }
            }
            onClicked: nas.installAll()
          }

          Button {
            id: openButton
            visible: nas.configured
            width: parent.width
            text: "Open Apps in TrueNAS"
            iconText: "󰖟"
            leftAlign: true
            hasCursor: nasPanel.cursorActive && nasPanel.rowAt(nasPanel.cursorIndex)
              && nasPanel.rowAt(nasPanel.cursorIndex).kind === "open"
            foreground: nasPanel.foreground
            fontFamily: nasPanel.fontFamily
            onHovered: function(on) {
              if (!on) return
              for (var i = 0; i < nasPanel.navRows.length; i++) {
                if (nasPanel.navRows[i].kind === "open") { nasPanel.setCursor(i); return }
              }
            }
            onClicked: nas.openWebUi()
          }

          Text {
            textFormat: Text.PlainText
            visible: nas.lastCheckedText !== ""
            width: parent.width
            text: "Last checked at " + nas.lastCheckedText
            color: nasPanel.dim
            font.family: nasPanel.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
          }
        }
      }

      // ----------------------------------------------------- settings view

      Flickable {
        id: settingsFlick
        anchors.fill: parent
        visible: nasPanel.showSettings
        contentWidth: width
        contentHeight: settingsColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            nasPanel.closeSettings()
            event.accepted = true
          }
        }

        Column {
          id: settingsColumn
          width: settingsFlick.width
          spacing: Style.space(10)

          RowLayout {
            width: parent.width
            spacing: Style.space(8)

            PanelActionButton {
              iconText: "󰅁"
              tooltipText: "Back"
              foreground: nasPanel.foreground
              fontFamily: nasPanel.fontFamily
              enabled: nas.configured
              Layout.alignment: Qt.AlignVCenter
              onClicked: nasPanel.closeSettings()
            }

            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              text: "Settings"
              color: nasPanel.foreground
              font.family: nasPanel.fontFamily
              font.pixelSize: Style.font.heading
              elide: Text.ElideRight
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "In TrueNAS, open the user menu → API Keys → Add. The key is stored in ~/.config/omarchy/truenas-apps-watcher/, readable only by you."
            color: nasPanel.dim
            font.family: nasPanel.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          PanelSectionHeader {
            text: "TRUENAS ADDRESS"
            foreground: nasPanel.foreground
            fontFamily: nasPanel.fontFamily
          }

          TextField {
            id: addressField
            width: parent.width
            foreground: nasPanel.foreground
            placeholderText: "truenas.local or https://nas.example.com"
            onTextChanged: nasPanel.editAddress = text
            onAccepted: apiKeyField.forceActiveFocus()
            Keys.onEscapePressed: nasPanel.closeSettings()
          }

          PanelSectionHeader {
            text: "API KEY"
            foreground: nasPanel.foreground
            fontFamily: nasPanel.fontFamily
          }

          TextField {
            id: apiKeyField
            width: parent.width
            foreground: nasPanel.foreground
            password: true
            placeholderText: "TrueNAS API key"
            onTextChanged: nasPanel.editApiKey = text
            onAccepted: nasPanel.saveSettings()
            Keys.onEscapePressed: nasPanel.closeSettings()
          }

          Toggle {
            width: parent.width
            label: "Accept self-signed certificate"
            description: "On by default — TrueNAS ships with one. Also covers Portainer."
            checked: nasPanel.editInsecure
            foreground: nasPanel.foreground
            fontFamily: nasPanel.fontFamily
            onClicked: nasPanel.editInsecure = !nasPanel.editInsecure
          }

          PanelSeparator {
            width: parent.width
            foreground: nasPanel.foreground
          }

          PanelSectionHeader {
            text: "PORTAINER (OPTIONAL)"
            foreground: nasPanel.foreground
            fontFamily: nasPanel.fontFamily
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "Watches containers TrueNAS doesn't manage — compose stacks, Dockge, anything hand-started — for newer images at their registry. Leave blank to skip."
            color: nasPanel.dim
            font.family: nasPanel.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          TextField {
            id: portainerAddressField
            width: parent.width
            foreground: nasPanel.foreground
            placeholderText: "truenas.local:31015"
            onTextChanged: nasPanel.editPortainerAddress = text
            onAccepted: portainerKeyField.forceActiveFocus()
            Keys.onEscapePressed: nasPanel.closeSettings()
          }

          TextField {
            id: portainerKeyField
            width: parent.width
            foreground: nasPanel.foreground
            password: true
            placeholderText: "Access token (user menu → My account)"
            onTextChanged: nasPanel.editPortainerApiKey = text
            onAccepted: nasPanel.saveSettings()
            Keys.onEscapePressed: nasPanel.closeSettings()
          }

          Button {
            width: parent.width
            text: nasPanel.settingsDirty ? "Save & connect" : "Saved"
            iconText: "󰆓"
            enabled: nasPanel.settingsDirty && nasPanel.settingsValid
            selected: nasPanel.settingsDirty
            foreground: nasPanel.foreground
            fontFamily: nasPanel.fontFamily
            bordered: true
            onClicked: nasPanel.saveSettings()
          }

          Text {
            textFormat: Text.PlainText
            visible: nasPanel.errorText !== ""
            width: parent.width
            text: nasPanel.errorText
            color: nasPanel.urgent
            font.family: nasPanel.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }

  // ------------------------------------------------------------ components

  component UpdateSection: Column {
    id: sectionColumn
    property string title: ""
    property string section: ""
    property string note: ""
    property var items: []

    visible: items.length > 0
    width: parent ? parent.width : 0
    spacing: Style.space(6)

    PanelSeparator {
      width: parent.width
      foreground: nasPanel.foreground
    }

    PanelSectionHeader {
      text: sectionColumn.title + " (" + sectionColumn.items.length + ")"
      foreground: nasPanel.foreground
      fontFamily: nasPanel.fontFamily
    }

    Text {
      textFormat: Text.PlainText
      visible: sectionColumn.note !== ""
      width: parent.width
      text: sectionColumn.note
      color: nasPanel.dim
      font.family: nasPanel.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    Repeater {
      model: sectionColumn.items
      UpdateRow {
        required property var modelData
        required property int index
        width: sectionColumn.width
        item: modelData
        navIndex: nasPanel.itemNavIndex(sectionColumn.section, index)
      }
    }
  }

  component UpdateRow: CursorSurface {
    id: updateRow
    property var item: null
    property int navIndex: -1
    readonly property bool isCursor: nasPanel.cursorActive && nasPanel.cursorIndex === navIndex

    hasCursor: isCursor
    foreground: nasPanel.foreground
    fill: nasPanel.hoverFill
    implicitHeight: rowLabels.implicitHeight + Style.spacing.rowPaddingX

    onIsCursorChanged: if (isCursor) nasPanel.cursorTarget = updateRow

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
      onContainsMouseChanged: if (containsMouse) nasPanel.setCursor(updateRow.navIndex)
    }

    ColumnLayout {
      id: rowLabels
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(1)

      Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        text: updateRow.item ? String(updateRow.item.title) : ""
        color: nasPanel.foreground
        font.family: nasPanel.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }

      Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        visible: text !== ""
        text: Model.versionsLine(updateRow.item)
        color: nasPanel.dim
        font.family: nasPanel.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
  }
}

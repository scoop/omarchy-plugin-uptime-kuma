import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "src/rows.js" as Rows

// The operator view: summoned deliberately, read quickly, dismissed.
//
// Problems come first, flattened out of the hierarchy — when something is
// broken you want to see what, not to go looking for it. Everything else stays
// folded into its group until asked for.
Item {
    id: root

    property string omarchyPath: ""
    property var shell: null
    property var manifest: null
    // Injected by the host for plugins that pair a UI with a service entry.
    property var service: null

    property bool opened: false
    property string filterText: ""
    property int selectedIndex: 0
    property var opened_: ({})

    readonly property var view: service && service.view ? service.view : null
    readonly property string connection: service ? service.connection : "setup"
    readonly property var rows: Rows.flatten(view, filterText, opened_)

    readonly property color foreground: Color.menu.text
    readonly property color dim: Qt.darker(foreground, 1.4)
    readonly property string fontFamily: Style.font.menuFamily

    function open() {
        opened = true;
        filterText = "";
        selectedIndex = firstSelectable(0, 1);
        disarmPointer();
        Qt.callLater(function () {
            if (setupForm.visible) {
                setupForm.focusFirstField();
            } else {
                keyCatcher.forceActiveFocus();
            }
        });
    }

    function close() {
        opened = false;
        filterText = "";
        setupForm.reset();
    }

    function toggle() {
        opened ? close() : open();
    }

    // Three states, three colours: alarm, attention, and confirmed-fine. Grey is
    // deliberately not used for "up" — grey is what "we don't know" looks like,
    // and this plugin has a real unknown state to spend it on.
    function statusColor(status) {
        if (status === "down") {
            return Color.urgent;
        }
        if (status === "degraded") {
            return Color.accent;
        }
        var ok = service ? service.okColor : Color.muted;
        // Calm, but still an assertion: this was checked and it passed.
        return Qt.rgba(ok.r, ok.g, ok.b, 0.8);
    }

    /** The next row the keyboard is allowed to land on. Headings are skipped. */
    function firstSelectable(from, step) {
        for (var i = from; i >= 0 && i < rows.length; i += step) {
            if (rows[i].selectable) {
                return i;
            }
        }
        return from;
    }

    /**
     * Ignore hover until the pointer has actually moved.
     *
     * Rows shift under a stationary pointer whenever the list changes — a
     * heartbeat arrives, a filter narrows, a group opens — and Qt reports that
     * as hover. Without this, the keyboard selection is yanked to wherever the
     * mouse happens to be resting.
     */
    function disarmPointer() {
        pointerGate.reset();
    }

    function selectFromPointer(index, item, mouse) {
        if (!pointerGate.moved(item, mouse)) {
            return;
        }
        if (rows[index] && rows[index].selectable) {
            selectedIndex = index;
        }
    }

    PointerMoveGate {
        id: pointerGate
        referenceItem: card
    }

    function select(delta) {
        if (rows.length === 0) {
            return;
        }
        var next = selectedIndex + delta;
        if (next < 0 || next >= rows.length) {
            return;
        }
        var landed = firstSelectable(next, delta > 0 ? 1 : -1);
        if (rows[landed] && rows[landed].selectable) {
            selectedIndex = landed;
            disarmPointer();
            list.positionViewAtIndex(selectedIndex, ListView.Contain);
        }
    }

    function activate() {
        var row = rows[selectedIndex];
        if (!row || !row.selectable) {
            return;
        }
        if (row.type === "group") {
            var next = {};
            for (var key in opened_) {
                next[key] = opened_[key];
            }
            next[row.id] = !next[row.id];
            opened_ = next;
            return;
        }
        // A monitor row opens where the operator can actually do something.
        var base = service ? String(service.baseUrl).replace(/\/+$/, "") : "";
        Quickshell.execDetached(["xdg-open", base + "/dashboard/" + row.id]);
        close();
    }

    /**
     * Whether this key press is the operator typing into the filter.
     *
     * Space counts: monitor names have spaces in them ("Home Assistant"), so a
     * filter that cannot accept one cannot find them.
     */
    function isTypedCharacter(event) {
        if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) {
            return false;
        }
        if (!event.text || event.text.length !== 1) {
            return false;
        }
        var code = event.text.charCodeAt(0);
        return code >= 32 && code !== 127;
    }

    // Whatever was typed before belongs to the list, not to a login screen.
    // Clearing on the way in means a password can never be sitting in the
    // filter line behind the form, or reappear when the form closes.
    onConnectionChanged: if (connection === "setup") filterText = ""

    onRowsChanged: {
        disarmPointer();
        if (rows.length && !rows[selectedIndex]) {
            selectedIndex = firstSelectable(0, 1);
        }
    }

    IpcHandler {
        target: "scoop.uptime-kuma"

        function open(): void {
            root.open();
        }
        function close(): void {
            root.close();
        }
        function show(): void {
            root.open();
        }
        function hide(): void {
            root.close();
        }
        function toggle(): void {
            root.toggle();
        }

        function inspect(): string {
            var r = root.rows[root.selectedIndex];
            return (
                "rows=" + root.rows.length +
                " idx=" + root.selectedIndex +
                " type=" + (r ? r.type : "none") +
                " label=" + (r ? r.label : "-") +
                " hasMonitorField=" + (r && "monitor" in r ? "yes" : "no") +
                " monitorNull=" + (r && r.monitor === null ? "yes" : "no") +
                " samples=" + (r && r.monitor && r.monitor.samples ? r.monitor.samples.length : -1) +
                " filterLen=" + root.filterText.length +
                " setupVisible=" + setupForm.visible
            );
        }
    }

    PanelWindow {
        id: panel
        visible: root.opened
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }
        color: "transparent"
        WlrLayershell.namespace: "scoop-uptime-kuma"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
        exclusionMode: ExclusionMode.Ignore

        Rectangle {
            anchors.fill: parent
            color: Color.menu.scrim
        }

        MouseArea {
            anchors.fill: parent
            onClicked: root.close()
        }

        BorderSurface {
            id: card
            // A card, not a takeover. space(380) is the house panel width; this
            // one carries a tree and an error line, so it runs a little wider.
            width: Math.min(Style.space(440), panel.width - Style.space(40))
            height: Math.min(Style.space(520), panel.height - Style.space(40))
            radius: Style.space(12)
            anchors.centerIn: parent
            color: Color.menu.background
            borderSpec: Border.surfaceSpec(
                "menu",
                "border",
                Color.menu.border,
                Math.max(1, Style.space(2))
            )

            MouseArea {
                anchors.fill: parent
                onClicked: {}
            }

            Item {
                id: keyCatcher
                // BorderSurface exposes its insets rather than laying children
                // out; anchoring to them is what keeps content off the border.
                anchors.fill: parent
                anchors.topMargin: card.contentTopInset + Style.space(14)
                anchors.bottomMargin: card.contentBottomInset + Style.space(14)
                anchors.leftMargin: card.contentLeftInset + Style.space(14)
                anchors.rightMargin: card.contentRightInset + Style.space(14)
                focus: true

                Keys.priority: Keys.BeforeItem
                Keys.onPressed: function (event) {
                    // The form owns the keyboard while it is up, unconditionally.
                    //
                    // Gating this on the form actually holding focus was wrong:
                    // if focus had not landed in a field yet, this catcher
                    // treated the keys as filter input — and put the operator's
                    // password on screen in the filter line. There is nothing to
                    // filter while the form is up, so never take keys here.
                    if (setupForm.visible) {
                        return;
                    }
                    if (event.key === Qt.Key_Escape) {
                        if (root.filterText) {
                            root.filterText = "";
                            root.selectedIndex = root.firstSelectable(0, 1);
                            root.disarmPointer();
                        } else {
                            root.close();
                        }
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Down) {
                        root.select(1);
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Up) {
                        root.select(-1);
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        root.activate();
                        event.accepted = true;
                    } else if (Util.editsFilter(event, root.filterText)) {
                        // Backspace and Ctrl+U only — Util does not handle typing.
                        root.filterText = Util.editedFilter(event, root.filterText);
                        root.selectedIndex = root.firstSelectable(0, 1);
                        root.disarmPointer();
                        event.accepted = true;
                    } else if (root.isTypedCharacter(event)) {
                        root.filterText = root.filterText + event.text;
                        root.selectedIndex = root.firstSelectable(0, 1);
                        root.disarmPointer();
                        event.accepted = true;
                    }
                }

                ColumnLayout {
                    anchors.fill: parent
                    spacing: Style.space(12)

                    PanelHero {
                        Layout.fillWidth: true
                        title: "Uptime Kuma"
                        meta: {
                            if (root.connection === "setup") {
                                return "Not configured";
                            }
                            if (!root.view) {
                                return "Connecting…";
                            }
                            var c = root.view.counts;
                            var parts = [c.up + " up"];
                            if (c.down > 0) {
                                parts.push(c.down + " down");
                            }
                            if (c.degraded > 0) {
                                parts.push(c.degraded + " degraded");
                            }
                            if (c.paused > 0) {
                                parts.push(c.paused + " paused");
                            }
                            return parts.join(" · ");
                        }
                        detail: root.filterText === "" ? "" : "Filtering: " + root.filterText
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                        iconComponent: Component {
                            Text {
                                text: "\uf21e"
                                color:
                                    root.connection === "unreachable"
                                        ? root.dim
                                        : root.view && root.view.counts.down > 0
                                          ? Color.urgent
                                          : root.foreground
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.display
                            }
                        }
                    }

                    // Stale data must announce itself. A healthy-looking pane
                    // that is merely out of date is the one lie this must not
                    // tell.
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: staleText.implicitHeight + Style.space(14)
                        visible: root.connection === "unreachable"
                        color: Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.14)
                        radius: Style.space(6)

                        Text {
                            id: staleText
                            anchors.centerIn: parent
                            text: "Can't reach Uptime Kuma — showing the last known state"
                            color: root.foreground
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            textFormat: Text.PlainText
                        }
                    }

                    PanelSeparator {
                        Layout.fillWidth: true
                        foreground: root.foreground
                    }

                    SetupForm {
                        id: setupForm
                        Layout.fillWidth: true
                        visible: root.connection === "setup"
                        service: root.service
                        shell: root.shell
                        moduleName: "scoop.uptime-kuma"
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                        onEscaped: keyCatcher.forceActiveFocus()
                        onVisibleChanged: {
                            if (visible && root.opened) {
                                Qt.callLater(focusFirstField);
                            }
                        }
                    }

                    ListView {
                        id: list
                        visible: !setupForm.visible
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true
                        spacing: Style.space(2)
                        model: root.rows
                        currentIndex: root.selectedIndex
                        boundsBehavior: Flickable.StopAtBounds
                        ScrollBar.vertical: ScrollBar {
                            policy: ScrollBar.AsNeeded
                        }

                        delegate: Item {
                            id: rowItem
                            required property var modelData
                            required property int index

                            readonly property bool isSection: modelData.type === "section"
                            readonly property bool isGroup: modelData.type === "group"
                            readonly property bool selected: index === root.selectedIndex && modelData.selectable
                            readonly property bool showsError: modelData.error !== "" && modelData.status === "down"

                            width: list.width
                            implicitHeight: isSection
                                ? sectionLabel.implicitHeight + Style.space(14)
                                : rowBody.implicitHeight + Style.space(9)

                            // ------------------------------------------ heading
                            PanelSectionHeader {
                                id: sectionLabel
                                visible: rowItem.isSection
                                anchors.left: parent.left
                                anchors.bottom: parent.bottom
                                anchors.bottomMargin: Style.space(4)
                                text: rowItem.modelData.label.toUpperCase()
                                foreground: root.foreground
                                fontFamily: root.fontFamily
                            }

                            // --------------------------------------------- row
                            Rectangle {
                                visible: !rowItem.isSection
                                anchors.fill: parent
                                radius: Style.space(6)
                                color: rowItem.selected ? Color.menu.selectedBackground : "transparent"
                            }

                            MouseArea {
                                visible: !rowItem.isSection
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onPositionChanged: function (mouse) {
                                    root.selectFromPointer(rowItem.index, rowItem, mouse);
                                }
                                onClicked: {
                                    root.selectedIndex = rowItem.index;
                                    root.activate();
                                }
                            }

                            RowLayout {
                                id: rowBody
                                visible: !rowItem.isSection
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.leftMargin: Style.space(rowItem.isGroup ? 8 : 20)
                                anchors.rightMargin: Style.space(10)
                                spacing: Style.space(8)

                                Rectangle {
                                    Layout.alignment: Qt.AlignVCenter
                                    width: Style.space(7)
                                    height: Style.space(7)
                                    radius: width / 2
                                    color: root.statusColor(rowItem.modelData.status)
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: Style.space(1)

                                    Text {
                                        Layout.fillWidth: true
                                        text: rowItem.modelData.label
                                        color: rowItem.selected ? Color.menu.selectedText : root.foreground
                                        font.family: root.fontFamily
                                        font.pixelSize: Style.font.body
                                        font.bold: rowItem.isGroup
                                        elide: Text.ElideRight
                                        textFormat: Text.PlainText
                                    }

                                    // The error text: the reason this plugin
                                    // uses the socket interface at all.
                                    Text {
                                        Layout.fillWidth: true
                                        visible: rowItem.showsError
                                        text: rowItem.modelData.error
                                        color: Color.urgent
                                        font.family: root.fontFamily
                                        font.pixelSize: Style.font.caption
                                        // The selected row shows its whole
                                        // error; the rest stay one line so the
                                        // list keeps its rhythm.
                                        wrapMode: rowItem.selected ? Text.WordWrap : Text.NoWrap
                                        maximumLineCount: rowItem.selected ? 6 : 1
                                        elide: Text.ElideRight
                                        textFormat: Text.PlainText
                                    }
                                }

                                Text {
                                    Layout.alignment: Qt.AlignVCenter
                                    text: rowItem.modelData.detail
                                    color: root.dim
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.caption
                                    textFormat: Text.PlainText
                                }
                            }
                        }
                    }

                    DetailView {
                        Layout.fillWidth: true
                        visible: !setupForm.visible
                        monitor: root.rows[root.selectedIndex]
                            ? root.rows[root.selectedIndex].monitor
                            : null
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                        okColor: root.service ? root.service.okColor : Color.muted
                    }

                    PanelSeparator {
                        Layout.fillWidth: true
                        foreground: root.foreground
                    }

                    Text {
                        Layout.fillWidth: true
                        text: "type to filter · ↑↓ move · enter open · esc close"
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        horizontalAlignment: Text.AlignHCenter
                        textFormat: Text.PlainText
                    }
                }
            }
        }
    }
}
